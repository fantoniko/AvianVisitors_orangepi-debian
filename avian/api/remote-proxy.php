<?php
// Optional split-LAN proxy.
//
// Set AV_BIRDNET_API_BASE on the web host to make selected read-only API
// endpoints forward to the BirdNET-Pi machine, for example:
//   AV_BIRDNET_API_BASE=http://orange-pi.local:8079/avian/api
//
// The endpoint name is supplied by local PHP code, not by the request, so this
// cannot be used as a general-purpose open proxy.

declare(strict_types=1);

function avian_remote_api_base(): ?string {
    $base = trim((string)(getenv('AV_BIRDNET_API_BASE') ?: ''));
    if ($base === '' && function_exists('apache_getenv')) {
        $base = trim((string)(apache_getenv('AV_BIRDNET_API_BASE') ?: ''));
    }
    if ($base === '') return null;

    $parts = parse_url($base);
    $scheme = strtolower((string)($parts['scheme'] ?? ''));
    if (($scheme !== 'http' && $scheme !== 'https') || empty($parts['host'])) {
        http_response_code(500);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'invalid AV_BIRDNET_API_BASE';
        exit;
    }
    if (isset($parts['user']) || isset($parts['pass']) || isset($parts['query']) || isset($parts['fragment'])) {
        http_response_code(500);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'invalid AV_BIRDNET_API_BASE';
        exit;
    }

    return rtrim($base, '/');
}

function avian_remote_request_url(string $endpoint): ?string {
    if (!preg_match('/^[A-Za-z0-9._-]+\.php$/', $endpoint)) {
        http_response_code(500);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'invalid proxy endpoint';
        exit;
    }

    $base = avian_remote_api_base();
    if ($base === null) return null;

    $url = $base . '/' . $endpoint;
    $query = (string)($_SERVER['QUERY_STRING'] ?? '');
    if ($query !== '') $url .= '?' . $query;
    return $url;
}

function avian_forward_remote_api(string $endpoint, int $timeoutSeconds = 20): void {
    $url = avian_remote_request_url($endpoint);
    if ($url === null) return;

    $method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    if ($method !== 'GET' && $method !== 'HEAD') {
        http_response_code(405);
        header('Allow: GET, HEAD');
        header('Content-Type: text/plain; charset=utf-8');
        echo 'remote split mode allows only GET and HEAD';
        exit;
    }

    if (function_exists('curl_init')) {
        avian_forward_remote_api_curl($url, $method, $timeoutSeconds);
        exit;
    }

    avian_forward_remote_api_stream($url, $method, $timeoutSeconds);
    exit;
}

function avian_forward_headers(): array {
    $headers = [];
    $pass = [
        'HTTP_ACCEPT' => 'Accept',
        'HTTP_IF_NONE_MATCH' => 'If-None-Match',
        'HTTP_IF_MODIFIED_SINCE' => 'If-Modified-Since',
        'HTTP_RANGE' => 'Range',
    ];
    foreach ($pass as $serverKey => $headerName) {
        if (!empty($_SERVER[$serverKey])) {
            $headers[] = $headerName . ': ' . (string)$_SERVER[$serverKey];
        }
    }
    return $headers;
}

function avian_relay_header(string $line): void {
    $line = trim($line);
    if ($line === '' || stripos($line, 'HTTP/') === 0) return;

    $name = strtolower(strtok($line, ':') ?: '');
    $allowed = [
        'accept-ranges' => true,
        'cache-control' => true,
        'content-length' => true,
        'content-range' => true,
        'content-type' => true,
        'etag' => true,
        'last-modified' => true,
    ];
    if (isset($allowed[$name])) header($line, true);
}

function avian_forward_remote_api_curl(string $url, string $method, int $timeoutSeconds): void {
    $headers = [];
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_HEADER => false,
        CURLOPT_HTTPHEADER => avian_forward_headers(),
        CURLOPT_NOBODY => $method === 'HEAD',
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => $timeoutSeconds,
        CURLOPT_HEADERFUNCTION => function ($ch, string $line) use (&$headers): int {
            $trimmed = trim($line);
            if (stripos($trimmed, 'HTTP/') === 0) $headers = [];
            if ($trimmed !== '') $headers[] = $trimmed;
            return strlen($line);
        },
    ]);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $err = curl_error($ch);
    curl_close($ch);

    if ($body === false || $status === 0) {
        http_response_code(502);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'remote BirdNET API request failed';
        if ($err !== '') echo ': ' . $err;
        return;
    }

    http_response_code($status);
    foreach ($headers as $line) avian_relay_header($line);
    if ($method !== 'HEAD') echo $body;
}

function avian_forward_remote_api_stream(string $url, string $method, int $timeoutSeconds): void {
    $context = stream_context_create([
        'http' => [
            'method' => $method,
            'header' => implode("\r\n", avian_forward_headers()),
            'ignore_errors' => true,
            'timeout' => $timeoutSeconds,
        ],
    ]);
    $body = @file_get_contents($url, false, $context);
    $headers = $http_response_header ?? [];
    $status = 502;
    foreach ($headers as $line) {
        if (preg_match('/^HTTP\/\S+\s+(\d{3})\b/', $line, $m)) {
            $status = (int)$m[1];
        }
    }

    if ($body === false && !$headers) {
        http_response_code(502);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'remote BirdNET API request failed';
        return;
    }

    http_response_code($status);
    foreach ($headers as $line) avian_relay_header($line);
    if ($method !== 'HEAD' && $body !== false) echo $body;
}
