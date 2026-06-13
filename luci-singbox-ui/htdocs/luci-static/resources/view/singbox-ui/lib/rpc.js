'use strict';
'require rpc';

return L.Class.extend({
    callRefresh:     rpc.declare({ object: 'singbox-ui', method: 'refresh',
                                   params: [ 'what', 'name' ] }),
    callRestart:    rpc.declare({ object: 'singbox-ui', method: 'restart' }),
    callStatus:     rpc.declare({ object: 'singbox-ui', method: 'status' }),
    callReadConfig: rpc.declare({ object: 'singbox-ui', method: 'read_config' }),
    callClashGet:    rpc.declare({ object: 'singbox-ui', method: 'clash_get',
                                   params: [ 'path' ] }),
    callClashMutate: rpc.declare({ object: 'singbox-ui', method: 'clash_mutate',
                                   params: [ 'method', 'path', 'body' ] }),
    callClashDelay:  rpc.declare({ object: 'singbox-ui', method: 'clash_delay',
                                   params: [ 'name', 'url', 'timeout' ] }),
    callSubStatus:   rpc.declare({ object: 'singbox-ui', method: 'sub_status' }),
    callExportSection: rpc.declare({ object: 'singbox-ui', method: 'export_section',
                                     params: [ 'kind', 'name' ] }),
    callPreviewConfig: rpc.declare({ object: 'singbox-ui', method: 'preview_config' }),
    callDhcpLeases: rpc.declare({ object: 'luci-rpc',   method: 'getDHCPLeases',
                                  expect: { '': {} } }),

});
