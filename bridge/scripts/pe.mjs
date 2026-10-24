/** Remove the original Authenticode certificate before injecting a modified Windows executable. */
export function stripCertificate(input) {
  const data = Buffer.from(input);
  if (data.length < 64 || data.toString('ascii', 0, 2) !== 'MZ') throw new Error('Invalid Windows executable');
  const pe = data.readUInt32LE(0x3c);
  if (pe > data.length - 24 || data.readUInt32LE(pe) !== 0x4550) throw new Error('Invalid PE header');
  const optional = pe + 24;
  const size = data.readUInt16LE(pe + 20);
  if (size < 2 || optional + size > data.length) throw new Error('Truncated PE header');
  const magic = data.readUInt16LE(optional);
  if (magic !== 0x10b && magic !== 0x20b) throw new Error('Unsupported PE format');
  const directories = magic === 0x20b ? 112 : 96;
  if (size < directories + 40 || data.readUInt32LE(optional + directories - 4) < 5) throw new Error('Missing PE data directories');
  const certificate = optional + directories + 32;
  const offset = data.readUInt32LE(certificate), length = data.readUInt32LE(certificate + 4);
  if (offset === 0 && length === 0) return data;
  if (!offset || !length || offset < optional + size || offset > data.length - length) throw new Error('Invalid PE certificate table');
  data.fill(0, certificate, certificate + 8);
  return offset + length === data.length ? data.subarray(0, offset) : data;
}
