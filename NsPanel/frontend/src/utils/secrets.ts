/** Password generation and the firewall-scope choices shared by the install forms. */

const ALPHANUM =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/** Alphanumeric only — the backend rejects characters that are unsafe in the
 *  SQL strings, unit files and env files the install scripts build. */
export function generatePassword(length = 24): string {
  const values = new Uint32Array(length);
  crypto.getRandomValues(values);
  return Array.from(values, (value) => ALPHANUM[value % ALPHANUM.length]).join(
    "",
  );
}

/** Fixed subnets an install may open a port to (mirrors core/validators.py). */
export const SUBNET_OPTIONS = [
  { cidr: "10.0.0.0/8", label: "Class A — private" },
  { cidr: "172.16.0.0/12", label: "Class B — private" },
  { cidr: "192.168.0.0/16", label: "Class C — private" },
  { cidr: "127.0.0.0/8", label: "Loopback (local)" },
  { cidr: "0.0.0.0/0", label: "Any IP — public" },
];

export const ANY_IP = "0.0.0.0/0";

/** Toggle one subnet in a selection map: "any" clears the rest, and vice versa. */
export function toggleSubnet(
  selected: Record<string, boolean>,
  cidr: string,
): void {
  const next = !selected[cidr];
  if (cidr === ANY_IP && next) {
    for (const key of Object.keys(selected)) selected[key] = false;
    selected[ANY_IP] = true;
    return;
  }
  selected[cidr] = next;
  if (next) selected[ANY_IP] = false;
}
