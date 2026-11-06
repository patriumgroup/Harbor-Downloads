<?php
class harbor_sso extends rcube_plugin {
    private array $credentials = [];
    private string $owner = '';
    public function init() {
        require_once '/usr/local/share/harbor/database-tools/sso-client.php';
        $this->owner = $_SERVER['HARBOR_OWNER'] ?? '';
        if (!preg_match('/\A[a-z][a-z0-9]{0,15}\z/', $this->owner)) { http_response_code(403); exit; }
        $this->add_hook('startup', [$this, 'startup']);
        $this->add_hook('authenticate', [$this, 'authenticate']);
        $this->add_hook('login_after', [$this, 'bound']);
    }
    public function startup(array $args): array {
        if (!empty($_SESSION['user_id']) && ($_SESSION['harbor_owner'] ?? '') !== $this->owner) {
            http_response_code(403); exit('Webmail session does not match the panel owner.');
        }
        if (empty($_SESSION['user_id']) && ($args['task'] ?? '') !== 'logout') {
            $args['task'] = 'login'; $args['action'] = 'login';
        }
        return $args;
    }
    public function authenticate(array $args): array {
        try {
            $this->credentials = harbor_tool_credentials('roundcube');
            $args['user'] = $this->credentials['username'];
            $args['pass'] = $this->credentials['password'];
            $args['host'] = 'ssl://'.$this->credentials['hostname'].':993';
            $args['cookiecheck'] = false; $args['valid'] = true;
        } catch (Throwable $error) { $args['abort'] = true; $args['error'] = 'SSO unavailable'; }
        return $args;
    }
    public function bound(array $args): array { $_SESSION['harbor_owner'] = $this->owner; return $args; }
}
