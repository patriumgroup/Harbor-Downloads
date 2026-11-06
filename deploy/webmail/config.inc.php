<?php
$owner = $_SERVER['HARBOR_OWNER'] ?? '';
if (!preg_match('/\A[a-z][a-z0-9]{0,15}\z/', $owner)) { http_response_code(403); exit; }
$config = [];
$config['db_dsnw'] = 'sqlite:////var/lib/harbor-roundcube/roundcube.sqlite?mode=0640';
$config['des_key'] = trim(file_get_contents('/etc/harbor/roundcube.secret'));
$server = json_decode(file_get_contents('/etc/harbor/mail/server.json'), true, 8, JSON_THROW_ON_ERROR)['hostname'];
if (!preg_match('/\A[a-z0-9][a-z0-9.-]{1,251}[a-z0-9]\z/', $server) || strlen($config['des_key']) !== 24) { http_response_code(503); exit; }
$config['imap_host'] = 'ssl://'.$server.':993';
$config['smtp_host'] = 'ssl://'.$server.':465';
$config['smtp_user'] = '%u'; $config['smtp_pass'] = '%p';
$config['imap_conn_options'] = ['ssl'=>['verify_peer'=>true,'verify_peer_name'=>true,'allow_self_signed'=>false]];
$config['smtp_conn_options'] = $config['imap_conn_options'];
$config['session_name'] = 'harbor_rc_'.$owner;
$config['session_auth_name'] = 'harbor_rc_auth_'.$owner;
$config['session_samesite'] = 'Strict';
$config['session_path'] = '/tools/roundcube';
$config['session_domain'] = '';
$config['use_https'] = true; $config['session_lifetime'] = 60;
$config['ip_check'] = false;
$config['plugins'] = ['harbor_sso'];
$config['product_name'] = 'Webmail';
$config['skin'] = 'elastic';
$config['temp_dir'] = '/var/lib/harbor-roundcube/tmp';
$config['log_dir'] = '/var/lib/harbor-roundcube/logs';
$config['junk_mbox'] = 'Junk'; $config['trash_mbox'] = 'Trash'; $config['sent_mbox'] = 'Sent'; $config['drafts_mbox'] = 'Drafts';
$config['create_default_folders'] = true;
$config['login_username_filter'] = 'email';
$config['identities_level'] = 4;
$config['enable_installer'] = false;
$config['auto_create_user'] = true;
$config['debug_level'] = 1;
$config['imap_debug'] = false; $config['smtp_debug'] = false; $config['sql_debug'] = false;
