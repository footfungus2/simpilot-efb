// A small interpreter for MSFS "RPN" calculator code, enough to run the HubHop/MobiFlight presets that drive
// add-on aircraft such as the Fenix A320, e.g.
//   (L:S_PED_RMP1_XFER) ++ (>L:S_PED_RMP1_XFER)
//   (L:S_FCU_ATHR) s0 2 % 0 != if{ l0 ++ (>L:S_FCU_ATHR) }
//   @ 1023 / 0 max 1 min (>L:A_FCU_LIGHTING)
// Only L: variables are read and written; `@` is the value passed with the command.

export interface RpnEnv {
  read(name: string): number;
  write(name: string, value: number): void;
}

const VAR = /^\((>?)L:([^,)]+?)\s*(?:,\s*[^)]*)?\)$/i;
const TOKEN = /\(>?[A-Z]:[^)]*\)|if\{|els\{|\}|[^\s{}]+/gi;

function tokenize(code: string): string[] {
  return code.match(TOKEN) ?? [];
}

/** L: variables a piece of code reads and writes (names without the `L:` prefix). */
export function rpnVars(code: string): { reads: string[]; writes: string[] } {
  const reads = new Set<string>();
  const writes = new Set<string>();
  for (const t of tokenize(code)) {
    const m = VAR.exec(t);
    if (m) (m[1] ? writes : reads).add(m[2]!.trim());
  }
  return { reads: [...reads], writes: [...writes] };
}

export function runRpn(code: string, env: RpnEnv, param = 0): void {
  if (!Number.isFinite(param)) throw new Error('RPN value must be finite');
  const tokens = tokenize(code);
  const stack: number[] = [];
  const regs: number[] = new Array(10).fill(0);
  const writes: [string, number][] = [];
  const values = new Map<string, number>();
  const pop = (): number => stack.pop() ?? 0;
  const top = (): number => stack[stack.length - 1] ?? 0;

  /** Index just past the `}` matching the block that starts at `i` (the token after `if{`/`els{`). */
  const skipBlock = (i: number): number => {
    let depth = 1;
    for (; i < tokens.length; i++) {
      const t = tokens[i]!.toLowerCase();
      if (t === 'if{' || t === 'els{') depth++;
      else if (t === '}' && --depth === 0) return i + 1;
    }
    return i;
  };

  const exec = (start: number, end: number): void => {
    let i = start;
    while (i < end) {
      const raw = tokens[i]!;
      const t = raw.toLowerCase();
      i++;
      const v = VAR.exec(raw);
      if (v) {
        const name = v[2]!.trim();
        if (v[1]) {
          const value = pop();
          if (!Number.isFinite(value)) throw new Error('RPN result must be finite');
          values.set(name, value);
          writes.push([name, value]);
        } else stack.push(values.get(name) ?? env.read(name));
        continue;
      }
      if (t === 'if{') {
        const cond = pop();
        const blockEnd = skipBlock(i); // just past this block's `}`
        const hasElse = tokens[blockEnd]?.toLowerCase() === 'els{';
        const elseEnd = hasElse ? skipBlock(blockEnd + 1) : blockEnd;
        if (cond !== 0) exec(i, blockEnd - 1);
        else if (hasElse) exec(blockEnd + 1, elseEnd - 1);
        i = elseEnd;
        continue;
      }
      if (t === '}' || t === 'els{') continue; // stray; blocks are handled by if{
      if (t === '@') {
        stack.push(param);
        continue;
      }
      const reg = /^([sl])([0-9])$/.exec(t);
      if (reg) {
        if (reg[1] === 's') regs[Number(reg[2])] = top();
        else stack.push(regs[Number(reg[2])]!);
        continue;
      }
      const n = Number(raw);
      if (raw !== '' && !Number.isNaN(n)) {
        stack.push(n);
        continue;
      }
      switch (t) {
        case '++': stack.push(pop() + 1); break;
        case '--': stack.push(pop() - 1); break;
        case '!': case 'not': stack.push(pop() === 0 ? 1 : 0); break;
        case 'neg': stack.push(-pop()); break;
        case 'abs': stack.push(Math.abs(pop())); break;
        case 'flr': stack.push(Math.floor(pop())); break;
        case 'ceil': stack.push(Math.ceil(pop())); break;
        case 'near': stack.push(Math.round(pop())); break;
        case 'd': stack.push(top()); break;
        case 'p': pop(); break;
        case 'r': { const b = pop(); const a = pop(); stack.push(b, a); break; }
        default: {
          const b = pop();
          const a = pop();
          switch (t) {
            case '+': stack.push(a + b); break;
            case '-': stack.push(a - b); break;
            case '*': stack.push(a * b); break;
            case '/': stack.push(b === 0 ? 0 : a / b); break;
            case '%': stack.push(b === 0 ? 0 : a % b); break;
            case 'min': stack.push(Math.min(a, b)); break;
            case 'max': stack.push(Math.max(a, b)); break;
            case '==': stack.push(a === b ? 1 : 0); break;
            case '!=': stack.push(a !== b ? 1 : 0); break;
            case '<': case 'lt': stack.push(a < b ? 1 : 0); break;
            case '>': case 'gt': stack.push(a > b ? 1 : 0); break;
            case '<=': stack.push(a <= b ? 1 : 0); break;
            case '>=': stack.push(a >= b ? 1 : 0); break;
            case 'and': case '&&': stack.push(a !== 0 && b !== 0 ? 1 : 0); break;
            case 'or': case '||': stack.push(a !== 0 || b !== 0 ? 1 : 0); break;
            default: throw new Error(`unsupported RPN token "${raw}"`);
          }
        }
      }
    }
  };
  exec(0, tokens.length);
  // Validate the entire preset before any simulator write, while preserving write/read order within it.
  for (const [name, value] of writes) env.write(name, value);
}
