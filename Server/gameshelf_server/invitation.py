"""Credential-free client invitations from explicit operator configuration only."""
import ipaddress
import json
import re
import unicodedata
from urllib.parse import urlsplit


def public_address(value):
    if not isinstance(value,str) or not value or len(value)>2048 or any(c.isspace() or unicodedata.category(c).startswith('C') for c in value) or any(c in value for c in '\\%?#'):
        raise ValueError('Invalid invitation HTTPS address')
    parts=urlsplit(value)
    if parts.scheme.lower()!='https' or not parts.hostname or parts.username is not None or parts.password is not None or parts.path not in ('','/') or parts.query or parts.fragment or parts.netloc.endswith(':'):
        raise ValueError('Invitation requires a credential-free HTTPS root address')
    port=parts.port  # urllib rejects malformed and out-of-range ports.
    if port is not None and not 1<=port<=65535:
        raise ValueError('Invalid invitation port')
    host=parts.hostname
    try:
        address=ipaddress.ip_address(host)
        host='['+str(address)+']' if address.version==6 else str(address)
    except ValueError:
        host=host.encode('idna').decode('ascii').lower()
        if len(host)>253 or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',label) for label in host.rstrip('.').split('.')):
            raise ValueError('Invalid invitation hostname')
    return 'https://'+host+(':'+str(port) if port is not None else '')


def certificate_pin(value):
    if value is None or value=='':
        return None
    if not isinstance(value,str):
        raise ValueError('Invalid invitation certificate SHA-256')
    value=value.strip().replace(':','').lower()
    if not re.fullmatch('[0-9a-f]{64}',value):
        raise ValueError('Invalid invitation certificate SHA-256')
    return value


def client_invitation(address,name=None,pin=None):
    # Deliberate whitelist: never serialize a service, account or session object.
    result=dict(version=1,address=public_address(address))
    if name is not None:
        if not isinstance(name,str) or not name or len(name)>80 or any(unicodedata.category(c).startswith('C') for c in name):
            raise ValueError('Invalid invitation name')
        result['name']=name
    pin=certificate_pin(pin)
    if pin:
        result['certificateSHA256']=pin
    if len(json.dumps(result,ensure_ascii=False).encode('utf-8'))>4096:
        raise ValueError('Invitation exceeds client size limit')
    return result
