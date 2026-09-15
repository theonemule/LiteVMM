#!/bin/sh
# Purpose: FastCGI entry point for VMAPI HTTP requests.
# Input comes from the web server CGI environment; responses are emitted as HTTP headers plus JSON.
# Keep authorization and validation ahead of commands that change host state.
# Dedicated peer entry point: require web-server Basic authentication even
# when the CGI alias is requested directly.
export VMAPI_PEER_API=true
exec /usr/lib/vmapi/cgi/api.cgi
