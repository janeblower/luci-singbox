'use strict';
'require rpc';

return L.Class.extend({
    // async:true forks the subscription fetch and answers at once — poll
    // sub_status().progress (SbCommon.waitSubRefresh) for the outcome.
    callRefresh:     rpc.declare({ object: 'singbox-ui', method: 'refresh',
                                   params: [ 'what', 'name', 'async' ] }),
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
    // tag -> { name, type, link }: the side-car that carries the human-readable
    // node name (the sing-box tag is ASCII-safe and often a content hash).
    callOutboundMeta: rpc.declare({ object: 'singbox-ui', method: 'outbound_meta' }),
    callExportSection: rpc.declare({ object: 'singbox-ui', method: 'export_section',
                                     params: [ 'kind', 'name' ] }),
    callPreviewConfig: rpc.declare({ object: 'singbox-ui', method: 'preview_config' }),
    callDhcpLeases: rpc.declare({ object: 'luci-rpc',   method: 'getDHCPLeases',
                                  expect: { '': {} } }),

});
