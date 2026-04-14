// SPDX-License-Identifier: AGPL-3.0-or-later
// Aerie GUI Bridge

/**
 * Wraps the Aerie AffineScript Wasm module.
 */
class AerieTEA {
  constructor(exports) {
    this.exports = exports;
    this.memory = exports.memory;
  }

  init() {
    return this.exports.aerie_init();
  }

  update(msg, model) {
    return this.exports.aerie_update(msg, model);
  }

  view(model) {
    const ptr = this.exports.aerie_view(model);
    return this.readString(ptr);
  }

  subs(model) {
    const ptr = this.exports.aerie_subs(model);
    return this.readString(ptr);
  }

  readString(ptr) {
    const view = new DataView(this.memory.buffer);
    const len = view.getInt32(ptr, true);
    const bytes = new Uint8Array(this.memory.buffer, ptr + 4, len);
    return new TextDecoder().decode(bytes);
  }
}

export async function load(url) {
  const response = await fetch(url);
  const bytes = await response.arrayBuffer();
  const importObject = {
    wasi_snapshot_preview1: {
      fd_write: (fd, iovs, iovs_len, nwritten) => 0
    }
  };
  const result = await WebAssembly.instantiate(bytes, importObject);
  return new AerieTEA(result.instance.exports);
}

export const Msg = {
  Navigate: (tool) => ({ tag: 0, value: tool }),
  PopState: () => ({ tag: 1 })
};

// Internal Wasm tags for Msg
export const MsgTag = {
  Navigate: 0,
  PopState: 1
};

export const DiagnosticTool = {
  Dashboard: 0,
  Speedtest: 1,
  BGP: 2,
  Jitter: 3
};
