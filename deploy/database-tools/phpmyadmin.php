<?php
// Install as /etc/phpmyadmin/conf.d/harbor.php. Only the dedicated FPM pool
// receives HARBOR_OWNER from the NGINX auth_request response, never HTTP input.
$owner = $_SERVER['HARBOR_OWNER'] ?? '';
$admin = getenv('HARBOR_TOOL_ROLE') === 'admin';
if ($admin ? $owner !== 'harboradmin' : !preg_match('/\A[a-z][a-z0-9]{0,15}\z/', $owner)) {
    http_response_code(403);
    exit('An authenticated Harbor owner is required.');
}
$allowed = [$admin ? 'harbor_admin_pma' : $owner.'_panel'];
$rules = [];
foreach ($allowed as $name) {
    if ($admin || preg_match('/\A'.preg_quote($owner, '/').'_[a-z][a-z0-9_]{0,14}\z/', $name)) {
        $rules[] = 'allow '.$name.' from all';
    }
}
$cfg['AllowArbitraryServer'] = false;
$cookieKey = trim(file_get_contents($admin ? '/etc/harbor/admin-phpmyadmin.secret' : '/etc/harbor/phpmyadmin.secret'));
if (!preg_match('/\A[0-9a-f]{64}\z/', $cookieKey)) {
    http_response_code(503);
    exit('Database tool configuration is incomplete.');
}
$cfg['blowfish_secret'] = hex2bin($cookieKey);
$cfg['Servers'] = [];
$cfg['Servers'][1] = [
    'verbose' => $admin ? 'Harbor administrator MariaDB' : 'Harbor MariaDB',
    'host' => 'localhost',
    'socket' => '/run/mysqld/mysqld.sock',
    'auth_type' => 'signon',
    'SignonScript' => '/usr/local/share/harbor/database-tools/signon.php',
    'SignonURL' => '/',
    'LogoutURL' => '/',
    'AllowRoot' => false,
    'AllowNoPassword' => false,
    'AllowDeny' => ['order' => 'explicit', 'rules' => $rules],
];
if (!$admin) {
    $cfg['Servers'][1]['hide_db'] = '^(mysql|information_schema|performance_schema|sys)$';
}
$cfg['CookieSameSite'] = 'Strict';
$cfg['TempDir'] = $admin ? '/var/lib/harbor-admin-phpmyadmin/tmp' : '/var/lib/harbor-phpmyadmin/tmp';
$cfg['SendErrorReports'] = 'never';
