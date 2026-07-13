<?php
// AvianVisitors - drawer menu items.
//
// Returns the list of links shown in the side drawer when a user clicks
// the menu button. The live JS expects {items: [{label, href, native}]}.
//
// Default LAN deploy: returns items immediately, no auth.
// Forwarded deploy:  set AV_REQUIRE_AUTH=1 in /etc/avian/env (or in your
// php-fpm pool's env block) AND configure Caddy basic_auth on /avian/api/
// to force the lock screen.

declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// If forwarded mode is on AND no Basic-auth header arrived, 401 so the
// frontend shows the lock screen. The actual credential check is done
// by Caddy (basic_auth directive in forwarding/caddy-auth.caddy); this
// PHP only checks that *some* Authorization header reached us.
if (getenv('AV_REQUIRE_AUTH') === '1' && empty($_SERVER['HTTP_AUTHORIZATION'])) {
    http_response_code(401);
    echo json_encode(['error' => 'unauthorized']);
    exit;
}

// The admin overlays operate on the machine running PHP: config.php reads and
// writes its local birdnet.conf, while birdnet-status.php calls local
// systemctl/journalctl. A split web host deliberately proxies only the
// read-only BirdNET data/media endpoints, so advertising these controls there
// creates four convincing but non-functional screens.
//
// AV_BIRDNET_API_BASE is set only on the split web host. Keep the controls on
// a normal BirdNET/Orange Pi install, but omit them from the web-host drawer.
// Service control and BirdNET configuration remain available at the Orange Pi
// URL, as documented in docs/split-lan-deployment.md.
$remoteApiBase = trim((string)(getenv('AV_BIRDNET_API_BASE') ?: ''));
if ($remoteApiBase === '' && function_exists('apache_getenv')) {
    $remoteApiBase = trim((string)(apache_getenv('AV_BIRDNET_API_BASE') ?: ''));
}
$splitWebHost = $remoteApiBase !== '';

$items = [];
if (!$splitWebHost) {
    // `native: true` tells the frontend to route through #admin=<section>.
    $items = [
        ['label' => 'settings', 'href' => '/#admin=settings', 'native' => true],
        ['label' => 'system',   'href' => '/#admin=system',   'native' => true],
        ['label' => 'logs',     'href' => '/#admin=logs',     'native' => true],
        ['label' => 'tools',    'href' => '/#admin=tools',    'native' => true],
    ];
}

echo json_encode([
    'items' => $items,
    'mode'  => $splitWebHost ? 'split-web-host' : 'birdnet-host',
]);
