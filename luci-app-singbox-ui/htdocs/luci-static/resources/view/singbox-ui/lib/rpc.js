'use strict';
'require rpc';

return L.Class.extend({
    callRefresh:    rpc.declare({ object: 'singbox-ui', method: 'refresh',     params: [ 'what' ] }),
    callRestart:    rpc.declare({ object: 'singbox-ui', method: 'restart' }),
    callStatus:     rpc.declare({ object: 'singbox-ui', method: 'status' }),
    callReadConfig: rpc.declare({ object: 'singbox-ui', method: 'read_config' }),
    callClash:      rpc.declare({ object: 'singbox-ui', method: 'clash_request',
                                  params: [ 'method', 'path', 'body' ] }),
    callExportSection: rpc.declare({ object: 'singbox-ui', method: 'export_section',
                                     params: [ 'kind', 'name' ] }),
    callPreviewConfig: rpc.declare({ object: 'singbox-ui', method: 'preview_config' }),
    callDhcpLeases: rpc.declare({ object: 'luci-rpc',   method: 'getDHCPLeases',
                                  expect: { '': {} } }),
});
