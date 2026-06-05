'use strict';
'require rpc';

return L.Class.extend({
    callRefresh:    rpc.declare({ object: 'singbox-ui', method: 'refresh',     params: [ 'what' ] }),
    callRestart:    rpc.declare({ object: 'singbox-ui', method: 'restart' }),
    callStatus:     rpc.declare({ object: 'singbox-ui', method: 'status' }),
    callReadConfig: rpc.declare({ object: 'singbox-ui', method: 'read_config' }),
    callClash:      rpc.declare({ object: 'singbox-ui', method: 'clash_request',
                                  params: [ 'method', 'path', 'body' ] }),
    callDhcpLeases: rpc.declare({ object: 'luci-rpc',   method: 'getDHCPLeases',
                                  expect: { '': {} } }),
});
