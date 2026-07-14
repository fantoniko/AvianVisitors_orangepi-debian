<?php
// AvianVisitors - bird image resolver.
//
// Lookup chain for /avian/api/cutout.php?sci=Calypte+anna:
//   1. ../assets/illustrations/<slug>.png   (generated illustration)
//   2. ../assets/cutouts/<slug>.png         (persistent Wikipedia/rembg cache)
//   3. fresh Wikipedia -> rembg -> cache (skipped gracefully if rembg unset)
//
// The frontend's <img src> points here for every species. Generated
// illustrations return instantly; cold misses fall through to the dynamic path.
//
// Default LAN deploy ships without auth. To expose publicly, gate
// /avian/api/* with basic_auth in your Caddyfile - see avian/forwarding/.

declare(strict_types=1);

$sci = trim((string)($_GET['sci'] ?? ''));
if ($sci === '') {
    http_response_code(400);
    echo 'sci required';
    exit;
}
// Binomial / trinomial pattern. Rejects path-traversal payloads and
// junk before any filesystem or upstream lookup.
if (!preg_match('/^[A-Za-z]{2,40}(?:[ ][a-z]{2,40}){1,3}$/', $sci)) {
    http_response_code(400);
    echo 'invalid sci';
    exit;
}

// Slugify scientific name for filename + cache key.
$slug = preg_replace('/[^a-z0-9]+/', '-', strtolower($sci));
$slug = trim((string)$slug, '-');

// pose=1 (default) is perched. pose=2 is flight. Clamp to a two-digit
// positive integer so a malformed ?pose= can't break the path.
$pose = (int)($_GET['pose'] ?? 1);
if ($pose < 1 || $pose > 99) $pose = 1;
$poseSuffix = $pose === 1 ? '' : "-$pose";

function serve_png(string $path): void {
    $size = (int)filesize($path);
    $mtime = (int)filemtime($path);
    $etag = '"' . dechex($mtime) . '-' . dechex($size) . '"';
    header('Content-Type: image/png');
    // Worker-generated files can change without a frontend release. Keep a
    // short freshness window and revalidate cheaply using file metadata.
    header('Cache-Control: public, max-age=300, must-revalidate');
    header('ETag: ' . $etag);
    header('Last-Modified: ' . gmdate('D, d M Y H:i:s', $mtime) . ' GMT');
    if (trim((string)($_SERVER['HTTP_IF_NONE_MATCH'] ?? '')) === $etag) {
        http_response_code(304);
        exit;
    }
    header('Content-Length: ' . (string)$size);
    readfile($path);
    exit;
}

function missing_image(string $message): void {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    // Do not retain a negative result: the worker may create the PNG shortly.
    header('Cache-Control: no-store');
    echo $message;
    exit;
}

// 1. Generated illustration with pose suffix.
$illustration = dirname(__DIR__) . "/assets/illustrations/{$slug}{$poseSuffix}.png";
if (is_file($illustration) && filesize($illustration) > 1024) {
    serve_png($illustration);
}
// Do not silently substitute the perched render for a missing flight pose.
// The frontend probes this endpoint and hides an unavailable pose on 404.
if ($pose !== 1) {
    missing_image('requested pose is unavailable');
}
// 2. Dynamic cache from a previous Wikipedia + rembg run.
$cacheDir = dirname(__DIR__) . '/assets/cutouts';
$cachePath = "$cacheDir/$slug.png";
if (is_file($cachePath) && filesize($cachePath) > 1024) {
    serve_png($cachePath);
}

// 3. Fresh Wikipedia fetch + rembg. Skipped if rembg-cli isn't on
//    PATH - the resolver returns a 404 in that case rather than
//    burning a Wikipedia request we can't use.
$rembg = '/usr/local/bin/rembg-cli';
if (!is_executable($rembg)) {
    missing_image('no generated illustration for ' . htmlspecialchars($sci) . ' (install rembg-cli to enable Wikipedia fallback)');
}

if (!is_dir($cacheDir)) @mkdir($cacheDir, 0755, true);

// Wikipedia's REST API asks for a contact-able identifier. Override
// via the AV_USER_AGENT env var (set in /etc/php/*/fpm/pool.d/www.conf
// or your shell) if your install hammers their endpoint at scale.
$ua = getenv('AV_USER_AGENT') ?: 'AvianVisitors/1.0 (+https://github.com/Twarner491/AvianVisitors)';
$ctx = stream_context_create([
    'http' => ['header' => "User-Agent: $ua\r\n", 'timeout' => 12],
]);
$wpUrl = 'https://en.wikipedia.org/api/rest_v1/page/summary/' . rawurlencode($sci);
$wpJson = @file_get_contents($wpUrl, false, $ctx);
$srcUrl = null;
if ($wpJson !== false) {
    $j = json_decode($wpJson, true);
    $srcUrl = $j['originalimage']['source'] ?? $j['thumbnail']['source'] ?? null;
}
// Defensive: only follow URLs on Wikimedia / Wikipedia hosts so a
// poisoned summary endpoint can't redirect us to arbitrary servers.
if ($srcUrl !== null) {
    $host = parse_url((string)$srcUrl, PHP_URL_HOST) ?: '';
    if (!preg_match('/(?:^|\.)(?:wikimedia\.org|wikipedia\.org)$/i', $host)) {
        $srcUrl = null;
    }
}
if (!$srcUrl) {
    missing_image('no Wikipedia photo for ' . htmlspecialchars($sci));
}

$imgBytes = @file_get_contents($srcUrl, false, $ctx);
if (!$imgBytes || strlen($imgBytes) < 1024) {
    http_response_code(503);
    echo 'failed to fetch source image';
    exit;
}

// rembg via the wrapper. u2netp = lightweight model (~50MB peak RAM -
// matters on the Pi 3B+). Temp files because rembg's CLI prefers
// real paths.
$tmpInBase  = tempnam(sys_get_temp_dir(), 'rembg-in-');
$tmpOutBase = tempnam(sys_get_temp_dir(), 'rembg-out-');
@unlink($tmpInBase); @unlink($tmpOutBase);
$tmpIn  = $tmpInBase  . '.jpg';
$tmpOut = $tmpOutBase . '.png';
file_put_contents($tmpIn, $imgBytes);

$cmd = sprintf(
    '%s i -m u2netp -ppm %s %s 2>&1',
    escapeshellarg($rembg),
    escapeshellarg($tmpIn),
    escapeshellarg($tmpOut)
);
$out = shell_exec($cmd);
@unlink($tmpIn);

if (!is_file($tmpOut) || filesize($tmpOut) < 1024) {
    @unlink($tmpOut);
    http_response_code(500);
    header('Content-Type: text/plain');
    echo "rembg failed (see your Pi's logs for details)";
    error_log("rembg failed for $sci: " . ($out ?? '(no output)'));
    exit;
}

// Tight-crop to the bird's bounding box + downscale to 800px max edge
// so cache stays small.
$im = @imagecreatefrompng($tmpOut);
if ($im !== false) {
    $cropped = @imagecropauto($im, IMG_CROP_TRANSPARENT);
    if ($cropped !== false) {
        imagedestroy($im);
        $im = $cropped;
    }
    $w = imagesx($im); $h = imagesy($im);
    $max = 800;
    if ($w > $max || $h > $max) {
        $scale = $max / max($w, $h);
        $nw = (int)($w * $scale); $nh = (int)($h * $scale);
        $resized = imagecreatetruecolor($nw, $nh);
        imagealphablending($resized, false);
        imagesavealpha($resized, true);
        imagecopyresampled($resized, $im, 0, 0, 0, 0, $nw, $nh, $w, $h);
        imagedestroy($im);
        $im = $resized;
    }
    imagealphablending($im, false);
    imagesavealpha($im, true);
    imagepng($im, $tmpOut, 6);
    imagedestroy($im);
}

// Atomic install: rename is atomic on the same filesystem, so any
// concurrent reader either sees the old cached file or the new one,
// never a half-written PNG.
@rename($tmpOut, $cachePath);
serve_png($cachePath);
