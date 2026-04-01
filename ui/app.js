const state = { files: [] };

const statusEl = document.getElementById('status');
const fileListEl = document.getElementById('fileList');
const resultEl = document.getElementById('result');
const logBoxEl = document.getElementById('logBox');
const dropzoneEl = document.getElementById('dropzone');
const fileInputEl = document.getElementById('fileInput');

function renderStatus(data) {
  const items = [
    ['kgg-dec.exe', data.tools.kggDec],
    ['unlockKuGoWin-64.exe', data.tools.unlock64],
    ['ffmpeg.exe', data.tools.ffmpeg],
    ['kgm.mask', data.tools.kgmMask],
    ['infra.dll', data.tools.infra],
    ['KGMusicV3.db', data.tools.kugouDb],
  ];
  statusEl.innerHTML = items.map(([name, ok]) => `
    <div class="status-item ${ok ? 'ok' : 'bad'}">
      <span>${name}</span>
      <strong>${ok ? '已就绪' : '缺失/未找到'}</strong>
    </div>
  `).join('');
}

function addFiles(fileList) {
  const supported = ['.kgg', '.kgm', '.kgma', '.flac'];
  for (const file of fileList) {
    const lower = file.name.toLowerCase();
    if (supported.some(ext => lower.endsWith(ext))) {
      if (!state.files.find(f => f.name === file.name && f.size === file.size)) {
        state.files.push(file);
      }
    }
  }
  renderFiles();
}

function renderFiles() {
  fileListEl.innerHTML = state.files.map((f, idx) => `<li>${idx + 1}. ${f.name} <span style="color:#94a3b8">(${(f.size/1024/1024).toFixed(2)} MB)</span></li>`).join('');
}

async function loadStatus() {
  const res = await fetch('/api/status');
  const data = await res.json();
  renderStatus(data);
}

async function fileToBase64(file) {
  const buffer = await file.arrayBuffer();
  let binary = '';
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

async function convertFiles() {
  if (!state.files.length) {
    resultEl.textContent = '请先选择至少一个文件。';
    return;
  }
  resultEl.textContent = '正在转换，请稍候...';
  logBoxEl.textContent = '正在读取文件并上传到本地转换服务...';

  const payloadFiles = [];
  for (const file of state.files) {
    logBoxEl.textContent = `正在准备：${file.name}`;
    const base64 = await fileToBase64(file);
    payloadFiles.push({ name: file.name, contentBase64: base64 });
  }

  const res = await fetch('/api/convert', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ files: payloadFiles }),
  });
  const data = await res.json();
  if (!data.ok) {
    resultEl.textContent = '转换失败：' + (data.error || '未知错误');
    return;
  }
  resultEl.textContent = `转换完成，输出 MP3 数量：${data.mp3Count}`;
  logBoxEl.textContent = (data.messages || []).join('\n');
}

document.getElementById('pickBtn').addEventListener('click', () => fileInputEl.click());
fileInputEl.addEventListener('change', (e) => addFiles(e.target.files));
document.getElementById('clearBtn').addEventListener('click', () => { state.files = []; fileInputEl.value=''; renderFiles(); resultEl.textContent=''; logBoxEl.textContent=''; });
document.getElementById('convertBtn').addEventListener('click', convertFiles);
document.getElementById('openOutputBtn').addEventListener('click', () => fetch('/api/open-output', { method: 'POST' }));
document.getElementById('openLogsBtn').addEventListener('click', () => fetch('/api/open-logs', { method: 'POST' }));

dropzoneEl.addEventListener('dragover', (e) => { e.preventDefault(); dropzoneEl.classList.add('drag'); });
dropzoneEl.addEventListener('dragleave', () => dropzoneEl.classList.remove('drag'));
dropzoneEl.addEventListener('drop', (e) => {
  e.preventDefault();
  dropzoneEl.classList.remove('drag');
  addFiles(e.dataTransfer.files);
});

loadStatus();
