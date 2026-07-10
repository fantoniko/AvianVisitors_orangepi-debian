<?php
// AvianVisitors - JSON facade over BirdNET-Pi's birds.db. Read-only.
// Symlinked into the BirdNET-Pi Caddy site root at /avian/api/.
//
// Endpoints (?action=...):
//   stats       - totals (detections, unique species, today, last hour)
//   lifelist    - every species with first_seen, last_seen, total_count
//   recent      - &hours=N (default 24): species heard in the window
//   species     - &sci=<sci_name>: per-species detail page
//   timeseries  - &days=N: daily detection counts per species
//   firstseen   - every species' earliest detection
//
// Default LAN deploy ships without auth. If you've exposed the Pi via
// Cloudflare or a tunnel, add a Caddy `basic_auth` matcher around the
// /avian/api/* path - see avian/forwarding/.

declare(strict_types=1);
require_once __DIR__ . '/remote-proxy.php';
avian_forward_remote_api('birdnet-api.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: public, max-age=30');

$tz = getenv('TZ') ?: '';
if ($tz === '' && is_readable('/etc/timezone')) {
    $tz = trim((string)file_get_contents('/etc/timezone'));
}
if ($tz !== '' && in_array($tz, DateTimeZone::listIdentifiers(), true)) {
    date_default_timezone_set($tz);
}

// PHP resolves __DIR__ through symlinks to the realpath. This script
// lives at $HOME/BirdNET-Pi/avian/api/birdnet-api.php (served via the
// ${EXTRACTED}/avian symlink). dirname(..., 2) walks to the BirdNET-Pi
// install root. Works under any username because we never bake the
// home directory in. getenv('HOME') would resolve to /var/lib/caddy
// under PHP-FPM (BirdNET-Pi runs it as the caddy user), so it can't
// be relied on.
$DB_PATH = dirname(__DIR__, 2) . '/scripts/birds.db';

if (!file_exists($DB_PATH)) {
    http_response_code(503);
    echo json_encode(['error' => 'birds.db not found']);
    exit;
}

try {
    $db = new SQLite3($DB_PATH, SQLITE3_OPEN_READONLY);
    $db->busyTimeout(2000);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'db open failed']);
    exit;
}

function rows(SQLite3 $db, string $sql, array $bind = []): array {
    $stmt = $db->prepare($sql);
    foreach ($bind as $k => $v) $stmt->bindValue($k, $v);
    $res = $stmt->execute();
    $out = [];
    while ($r = $res->fetchArray(SQLITE3_ASSOC)) $out[] = $r;
    return $out;
}
function one(SQLite3 $db, string $sql, array $bind = []) {
    $r = rows($db, $sql, $bind);
    return $r[0] ?? null;
}

$action = $_GET['action'] ?? 'stats';

switch ($action) {

    case 'stats': {
        $total       = (int)(one($db, 'SELECT COUNT(*) AS n FROM detections')['n'] ?? 0);
        $species     = (int)(one($db, 'SELECT COUNT(DISTINCT Sci_Name) AS n FROM detections')['n'] ?? 0);
        $today       = (int)(one($db, "SELECT COUNT(*) AS n FROM detections WHERE Date = DATE('now','localtime')")['n'] ?? 0);
        $todaySpec   = (int)(one($db, "SELECT COUNT(DISTINCT Sci_Name) AS n FROM detections WHERE Date = DATE('now','localtime')")['n'] ?? 0);
        $lastHour    = (int)(one($db, "SELECT COUNT(*) AS n FROM detections WHERE DATETIME(Date||' '||Time) BETWEEN DATETIME('now','localtime','-1 hour') AND DATETIME('now','localtime')")['n'] ?? 0);
        $week        = (int)(one($db, "SELECT COUNT(*) AS n FROM detections WHERE Date >= DATE('now','localtime','-6 day')")['n'] ?? 0);
        $weekSpec    = (int)(one($db, "SELECT COUNT(DISTINCT Sci_Name) AS n FROM detections WHERE Date >= DATE('now','localtime','-6 day')")['n'] ?? 0);
        $first       = one($db, 'SELECT MIN(Date) AS d FROM detections');
        echo json_encode([
            'totals'    => ['detections' => $total, 'species' => $species],
            'today'     => ['detections' => $today, 'species' => $todaySpec],
            'last_hour' => ['detections' => $lastHour],
            'week'      => ['detections' => $week,  'species' => $weekSpec],
            'started'   => $first['d'] ?? null,
            'as_of'     => date('c'),
        ]);
        break;
    }

    case 'lifelist': {
        // n = total calls (matches the `recent` action's alias so the
        // frontend can read either response interchangeably).
        $rs = rows($db,
          "SELECT Sci_Name AS sci, Com_Name AS com, MIN(Date||' '||Time) AS first_seen, "
        . "       MAX(Date||' '||Time) AS last_seen, COUNT(*) AS n, MAX(Confidence) AS best_conf "
        . "FROM detections GROUP BY Sci_Name ORDER BY first_seen ASC"
        );
        echo json_encode(['species' => $rs, 'as_of' => date('c')]);
        break;
    }

    case 'recent': {
        // Cap raised to 1,000,000 hours (~114 years) so the frontend's
        // "ALL" button can turn off the time filter without needing a
        // separate code path.
        $hours = max(1, min(1000000, (int)($_GET['hours'] ?? 24)));
        $cutoff = time() - ($hours * 3600);
        $cutoffDate = date('Y-m-d', $cutoff);
        $cutoffTime = date('H:i:s', $cutoff);
        // Compare the stored date and time columns directly so SQLite can use
        // detections_Date_Time instead of applying julianday() to every row.
        $rs = rows($db,
          "WITH windowed AS ("
        . "  SELECT *, ROW_NUMBER() OVER ("
        . "    PARTITION BY Sci_Name ORDER BY Confidence DESC, Date DESC, Time DESC"
        . "  ) AS confidence_rank "
        . "  FROM detections WHERE (Date, Time) >= (:cutoff_date, :cutoff_time)"
        . ") "
        . "SELECT Sci_Name AS sci, MAX(Com_Name) AS com, COUNT(*) AS n, "
        . "       MAX(Confidence) AS best_conf, MAX(Date||' '||Time) AS last_seen, "
        . "       MAX(CASE WHEN confidence_rank = 1 THEN File_Name END) AS top_file, "
        . "       MAX(CASE WHEN confidence_rank = 1 THEN Date||' '||Time END) AS top_at "
        . "FROM windowed GROUP BY Sci_Name ORDER BY last_seen DESC",
          [':cutoff_date' => $cutoffDate, ':cutoff_time' => $cutoffTime]
        );
        echo json_encode(['hours' => $hours, 'species' => $rs, 'as_of' => date('c')]);
        break;
    }

    case 'species': {
        $sci = $_GET['sci'] ?? '';
        if ($sci === '') { http_response_code(400); echo json_encode(['error' => 'sci= required']); break; }
        $detections = rows($db,
          "SELECT Date AS d, Time AS t, File_Name AS file, Confidence AS conf "
        . "FROM detections WHERE Sci_Name = :sn ORDER BY Date DESC, Time DESC LIMIT 500",
          [':sn' => $sci]
        );
        $summary = one($db,
          "SELECT Com_Name AS com, COUNT(*) AS total, MIN(Date||' '||Time) AS first_seen, "
        . "       MAX(Date||' '||Time) AS last_seen, MAX(Confidence) AS best_conf "
        . "FROM detections WHERE Sci_Name = :sn",
          [':sn' => $sci]
        );
        echo json_encode(['sci' => $sci, 'summary' => $summary, 'detections' => $detections]);
        break;
    }

    case 'timeseries': {
        // Aggregated time-bucketed counts for the stats charts.
        //   daily   - last $days days, detections + unique species per day
        //   by_hour - detections grouped by hour of day, last 30 days
        // The frontend backfills missing dates with zero - sparse data days
        // are otherwise dropped by the GROUP BY.
        $days = max(1, min(90, (int)($_GET['days'] ?? 30)));
        $daily = rows($db,
          "SELECT Date AS date, COUNT(*) AS detections, COUNT(DISTINCT Sci_Name) AS species "
        . "FROM detections "
        . "WHERE Date >= DATE('now','localtime','-".($days - 1)." day') "
        . "GROUP BY Date ORDER BY Date"
        );
        $by_hour = rows($db,
          "SELECT CAST(strftime('%H', Time) AS INT) AS hour, COUNT(*) AS detections "
        . "FROM detections "
        . "WHERE Date >= DATE('now','localtime','-30 day') "
        . "GROUP BY hour ORDER BY hour"
        );
        echo json_encode([
            'days'    => $days,
            'daily'   => $daily,
            'by_hour' => $by_hour,
            'as_of'   => date('c'),
        ]);
        break;
    }

    case 'firstseen': {
        // Most recent additions to the life list - first detection per
        // species, sorted by first_seen DESC. Powers the "First Detections"
        // section on the stats view.
        $limit = max(1, min(50, (int)($_GET['limit'] ?? 10)));
        $rs = rows($db,
          "SELECT Sci_Name AS sci, Com_Name AS com, MIN(Date||' '||Time) AS first_seen, "
        . "       COUNT(*) AS total "
        . "FROM detections GROUP BY Sci_Name ORDER BY first_seen DESC LIMIT :lim",
          [':lim' => $limit]
        );
        echo json_encode(['species' => $rs, 'as_of' => date('c')]);
        break;
    }

    default:
        http_response_code(404);
        echo json_encode(['error' => 'unknown action']);
}
