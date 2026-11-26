/** Input rules, mirroring core/validators.py, so forms flag mistakes inline
 *  before a request is made. The backend still validates everything.
 *
 * Each function returns an error message, or '' when the value is fine.
 */

const IPV4_PART = '(25[0-5]|2[0-4]\\d|1?\\d?\\d)';
export const IPV4 = new RegExp(`^${IPV4_PART}(\\.${IPV4_PART}){3}$`);
/** Unit and site names — also filenames under /var/www. */
export const NAME = /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/;
export const DOMAIN = /^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/;
export const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
export const PASSWORD_MIN = 12;

export function required(value: string, what = 'This field'): string {
  return value.trim() ? '' : `${what} is required.`;
}

export function ipv4(value: string): string {
  return IPV4.test(value.trim()) ? '' : 'Enter an IPv4 address, e.g. 192.168.1.10.';
}

export function cidr(value: string): string {
  const match = value.trim().match(/^(.+)\/(\d{1,2})$/);
  if (!match || !IPV4.test(match[1]) || Number(match[2]) > 32) {
    return 'Use CIDR notation, e.g. 192.168.1.0/24.';
  }
  return '';
}

/** Same subnet: the gateway of a static address must be on its network. */
export function sameSubnet(address: string, gateway: string): boolean {
  const match = address.trim().match(/^(.+)\/(\d{1,2})$/);
  if (!match || !IPV4.test(match[1]) || !IPV4.test(gateway.trim())) return false;
  const prefix = Number(match[2]);
  const toInt = (ip: string) => ip.split('.').reduce((acc, part) => (acc << 8) + Number(part), 0) >>> 0;
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  return (toInt(match[1]) & mask) === (toInt(gateway.trim()) & mask);
}

export function port(value: string | number, { min = 1, max = 65535 } = {}): string {
  const text = String(value).trim();
  if (!/^\d+$/.test(text)) return 'Enter a port number.';
  const n = Number(text);
  return n >= min && n <= max ? '' : `Use a port between ${min} and ${max}.`;
}

export function name(value: string, what = 'Name'): string {
  const v = value.trim();
  if (!v) return `${what} is required.`;
  if (!NAME.test(v) || v.includes('..'))
    return `${what}: letters, digits, . _ - only, starting with a letter or digit.`;
  return '';
}

export function domain(value: string): string {
  return DOMAIN.test(value.trim()) ? '' : 'Enter a domain such as app.example.com.';
}

/** A DNS record name: one or more labels; a TLD is not required (`db`, `db.lan`). */
export const DNS_NAME =
  /^(?=.{1,253}$)[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

export function dnsName(value: string): string {
  return DNS_NAME.test(value.trim())
    ? ''
    : 'Use letters, digits and hyphens, optionally with dots (db, db.lan).';
}

export function email(value: string): string {
  return !value.trim() || EMAIL.test(value.trim()) ? '' : 'Enter a valid e-mail address.';
}

export function password(value: string, min = PASSWORD_MIN): string {
  return value.length >= min ? '' : `Use at least ${min} characters.`;
}

/** The first non-empty message, for fields with several rules. */
export function first(...messages: string[]): string {
  return messages.find(Boolean) ?? '';
}
