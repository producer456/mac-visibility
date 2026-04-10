// Auto-generated — contains the web client HTML served by the Mac host

enum WebClientHTML {
    static let html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Mac Visibility</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0a0a0a;
    color: #fff;
    font-family: -apple-system, system-ui, sans-serif;
    overflow: hidden;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  #toolbar {
    background: #1a1a1a;
    padding: 8px 16px;
    display: flex;
    align-items: center;
    gap: 12px;
    border-bottom: 1px solid #333;
    z-index: 10;
  }
  #toolbar h1 {
    font-size: 14px;
    font-weight: 600;
    opacity: 0.9;
  }
  #status {
    font-size: 12px;
    padding: 3px 10px;
    border-radius: 10px;
    background: #333;
  }
  #status.connected { background: #1a472a; color: #4ade80; }
  #status.connecting { background: #422006; color: #fb923c; }
  #status.error { background: #450a0a; color: #f87171; }
  #stats {
    margin-left: auto;
    font-size: 11px;
    opacity: 0.5;
    font-variant-numeric: tabular-nums;
  }
  #fullscreen-btn {
    background: #333;
    border: none;
    color: #fff;
    padding: 4px 12px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 12px;
  }
  #fullscreen-btn:hover { background: #444; }
  #canvas-container {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    background: #000;
  }
  canvas {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
  }
  #overlay {
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0,0,0,0.85);
    z-index: 20;
  }
  #overlay.hidden { display: none; }
  .overlay-content {
    text-align: center;
  }
  .overlay-content h2 { font-size: 24px; margin-bottom: 8px; }
  .overlay-content p { opacity: 0.6; font-size: 14px; }
  .spinner {
    width: 40px; height: 40px;
    border: 3px solid #333;
    border-top-color: #4ade80;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    margin: 0 auto 16px;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
  <div id="toolbar">
    <h1>Mac Visibility</h1>
    <span id="status" class="connecting">Connecting...</span>
    <span id="stats"></span>
    <button id="fullscreen-btn" onclick="toggleFullscreen()">Fullscreen</button>
  </div>
  <div id="canvas-container">
    <canvas id="screen"></canvas>
  </div>
  <div id="overlay">
    <div class="overlay-content">
      <div class="spinner"></div>
      <h2>Connecting to Mac...</h2>
      <p>Establishing video stream</p>
    </div>
  </div>

<script>
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const statusEl = document.getElementById('status');
const statsEl = document.getElementById('stats');
const overlay = document.getElementById('overlay');

let ws = null;
let decoder = null;
let frameCount = 0;
let lastFpsTime = performance.now();
let fps = 0;
let totalBytes = 0;

function connect() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.binaryType = 'arraybuffer';

  ws.onopen = () => {
    statusEl.textContent = 'Connected';
    statusEl.className = 'connected';
    initDecoder();
  };

  ws.onmessage = (event) => {
    if (!decoder) return;
    const data = new Uint8Array(event.data);
    totalBytes += data.byteLength;

    // Parse NAL units and feed to decoder
    const nalUnits = parseNALUnits(data);
    for (const nalu of nalUnits) {
      const type = nalu[0] & 0x1F;

      if (type === 7) {
        // SPS
        decoder.configure({
          codec: 'avc1.640028', // H.264 Main profile
          optimizeForLatency: true,
        });
      }

      const chunk = new EncodedVideoChunk({
        type: type === 5 ? 'key' : 'delta',
        timestamp: performance.now() * 1000,
        data: nalu,
      });

      try {
        decoder.decode(chunk);
      } catch (e) {
        // Skip decode errors for non-VCL NALUs
      }
    }
  };

  ws.onclose = () => {
    statusEl.textContent = 'Disconnected';
    statusEl.className = 'error';
    overlay.classList.remove('hidden');
    overlay.querySelector('h2').textContent = 'Disconnected';
    overlay.querySelector('p').textContent = 'Reconnecting in 2s...';
    setTimeout(connect, 2000);
  };

  ws.onerror = () => {
    statusEl.textContent = 'Error';
    statusEl.className = 'error';
  };
}

function initDecoder() {
  if (!('VideoDecoder' in window)) {
    statusEl.textContent = 'WebCodecs not supported';
    statusEl.className = 'error';
    overlay.querySelector('h2').textContent = 'Browser not supported';
    overlay.querySelector('p').textContent = 'Use Chrome 94+ or Edge 94+';
    return;
  }

  decoder = new VideoDecoder({
    output: (frame) => {
      // Draw frame to canvas
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0);
      frame.close();

      // Hide overlay on first frame
      if (!overlay.classList.contains('hidden')) {
        overlay.classList.add('hidden');
      }

      // FPS counter
      frameCount++;
      const now = performance.now();
      if (now - lastFpsTime >= 1000) {
        fps = frameCount;
        frameCount = 0;
        lastFpsTime = now;
        const mbps = (totalBytes * 8 / 1_000_000).toFixed(1);
        statsEl.textContent = `${fps} fps | ${canvas.width}x${canvas.height} | ${mbps} Mbps total`;
        totalBytes = 0;
      }
    },
    error: (e) => {
      console.error('Decoder error:', e);
    },
  });
}

function parseNALUnits(data) {
  const units = [];
  let i = 0;

  while (i < data.length - 4) {
    // Find start code (0x00000001)
    if (data[i] === 0 && data[i+1] === 0 && data[i+2] === 0 && data[i+3] === 1) {
      // Find next start code or end
      let end = data.length;
      for (let j = i + 4; j < data.length - 3; j++) {
        if (data[j] === 0 && data[j+1] === 0 && data[j+2] === 0 && data[j+3] === 1) {
          end = j;
          break;
        }
      }
      units.push(data.slice(i + 4, end));
      i = end;
    } else {
      i++;
    }
  }

  return units;
}

function toggleFullscreen() {
  if (!document.fullscreenElement) {
    document.documentElement.requestFullscreen();
  } else {
    document.exitFullscreen();
  }
}

// Start
connect();
</script>
</body>
</html>
"""
}
