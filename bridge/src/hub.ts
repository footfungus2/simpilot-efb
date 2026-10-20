import type { WebSocket } from 'ws';
import { config } from './config.js';
import { logger } from './log.js';
import type { AppToBridge, BridgeStatus, BridgeToApp, Ownship } from './types.js';

const log = logger('hub');

/** Shared state and fan-out to connected iPads. */
export class Hub {
  private clients = new Set<WebSocket>();
  private simConnected = false;
  private aircraftTitle: string | undefined;
  private linkLastSeen: number | undefined;
  private linkWasConnected = false;
  lastOwnship: Ownship | undefined;
  private messageHandlers: ((msg: AppToBridge) => void)[] = [];

  constructor() {
    // Link liveness is only observed when it polls, so check for timeouts on a timer.
    setInterval(() => {
      const connected = this.linkConnected();
      if (connected !== this.linkWasConnected) {
        this.linkWasConnected = connected;
        log.info(connected ? 'in-sim link connected' : 'in-sim link lost');
        this.broadcastStatus();
      }
    }, 1000).unref();
  }

  status(): BridgeStatus {
    return {
      sim: { connected: this.simConnected, aircraftTitle: this.aircraftTitle },
      link: {
        connected: this.linkConnected(),
        lastSeenMs: this.linkLastSeen ? Date.now() - this.linkLastSeen : undefined,
      },
    };
  }

  private linkConnected(): boolean {
    return this.linkLastSeen !== undefined && Date.now() - this.linkLastSeen < config.linkTimeoutMs;
  }

  addClient(ws: WebSocket, remote: string): void {
    this.clients.add(ws);
    log.info(`app connected from ${remote} (${this.clients.size} total)`);
    this.send(ws, { t: 'hello', v: 1, bridgeVersion: config.bridgeVersion, status: this.status() });
    if (this.lastOwnship) this.send(ws, { t: 'ownship', ...this.lastOwnship });

    ws.on('message', (data) => {
      let msg: AppToBridge;
      try {
        msg = JSON.parse(String(data));
      } catch {
        log.warn(`ignoring non-JSON message from ${remote}`);
        return;
      }
      for (const h of this.messageHandlers) h(msg);
    });
    ws.on('close', () => {
      this.clients.delete(ws);
      log.info(`app disconnected from ${remote} (${this.clients.size} left)`);
    });
    ws.on('error', (err) => log.warn(`socket error from ${remote}: ${err.message}`));
  }

  onMessage(handler: (msg: AppToBridge) => void): void {
    this.messageHandlers.push(handler);
  }

  setSim(connected: boolean, aircraftTitle?: string): void {
    const changed = connected !== this.simConnected || aircraftTitle !== this.aircraftTitle;
    this.simConnected = connected;
    this.aircraftTitle = connected ? aircraftTitle : undefined;
    if (changed) this.broadcastStatus();
  }

  linkSeen(): void {
    this.linkLastSeen = Date.now();
    if (!this.linkWasConnected) {
      this.linkWasConnected = true;
      log.info('in-sim link connected');
      this.broadcastStatus();
    }
  }

  ownship(o: Ownship): void {
    this.lastOwnship = o;
    this.broadcast({ t: 'ownship', ...o });
  }

  broadcastStatus(): void {
    this.broadcast({ t: 'status', ...this.status() });
  }

  broadcast(msg: BridgeToApp): void {
    const data = JSON.stringify(msg);
    for (const ws of this.clients) {
      if (ws.readyState === ws.OPEN) ws.send(data);
    }
  }

  private send(ws: WebSocket, msg: BridgeToApp): void {
    ws.send(JSON.stringify(msg));
  }
}
