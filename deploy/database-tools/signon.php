<?php
require_once '/usr/local/share/harbor/database-tools/sso-client.php';
function get_login_credentials($ignored): array {
    try {
        $credentials = harbor_tool_credentials(getenv('HARBOR_TOOL_ROLE') === 'admin' ? 'admin-phpmyadmin' : 'phpmyadmin');
        return [$credentials['username'], $credentials['password']];
    } catch (Throwable $error) {
        http_response_code(503);
        exit('SSO provisioning unavailable. Return to the panel.');
    }
}
