<?php
declare(strict_types=1);
function harbor_tool_credentials(string $tool): array {
    $owner = $_SERVER['HARBOR_OWNER'] ?? '';
    $assertion = $_SERVER['HARBOR_ASSERTION'] ?? '';
    if (!preg_match('/\A[a-z][a-z0-9]{0,15}\z/', $owner) || !preg_match('/\A[0-9]{10}\.[a-f0-9]{64}\z/', $assertion)) {
        throw new RuntimeException('Authenticated tool access required');
    }
    $socket = stream_socket_client('unix:///run/harbor-agent/tools.sock', $error, $message, 3);
    if (!$socket) { throw new RuntimeException('SSO service unavailable'); }
    stream_set_timeout($socket, 30);
    try {
        $request = json_encode(['owner'=>$owner, 'tool'=>$tool, 'assertion'=>$assertion], JSON_THROW_ON_ERROR)."\n";
        $offset = 0;
        while ($offset < strlen($request)) {
            $written = fwrite($socket, substr($request, $offset));
            if (!$written) { throw new RuntimeException('SSO service unavailable'); }
            $offset += $written;
        }
        $reply = fgets($socket, 65537);
        if (!$reply || !str_ends_with($reply, "\n")) { throw new RuntimeException('Invalid SSO response'); }
        $response = json_decode($reply, true, 32, JSON_THROW_ON_ERROR);
        if (empty($response['ok'])) { throw new RuntimeException('SSO provisioning unavailable; inspect panel configuration'); }
        return $response['data'];
    } finally { fclose($socket); }
}
