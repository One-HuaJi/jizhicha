// ==================== 主题切换 ====================
const THEME_KEY = 'huse-vpn-theme';

function loadTheme() {
  const saved = localStorage.getItem(THEME_KEY);
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const theme = saved || (prefersDark ? 'dark' : 'light');
  applyTheme(theme);
}

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  const sun = document.getElementById('icon-sun');
  const moon = document.getElementById('icon-moon');
  if (sun && moon) {
    sun.style.display = theme === 'dark' ? 'block' : 'none';
    moon.style.display = theme === 'dark' ? 'none' : 'block';
  }
}

function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme') || 'light';
  const next = current === 'dark' ? 'light' : 'dark';
  applyTheme(next);
  localStorage.setItem(THEME_KEY, next);
}

// ==================== VPN 登录逻辑 ====================
const form = document.getElementById('loginForm');
const submitBtn = document.getElementById('submitBtn');
const cancelBtn = document.getElementById('cancelBtn');
const statusEl = document.getElementById('status');
let isConnecting = false;

function setStatus(message, type = 'info') {
  statusEl.textContent = message;
  statusEl.className = `status ${type} show`;
}

function setLoading(loading) {
  isConnecting = loading;
  submitBtn.disabled = loading;
  cancelBtn.disabled = !loading;
  const btnText = document.getElementById('btnText');
  if (loading) {
    btnText.innerHTML = '<span class="spinner"></span> 正在连接…';
  } else {
    btnText.textContent = '连接 VPN';
  }
}

async function invoke(command, payload) {
  // 优先使用 Tauri 官方 invoke API
  if (window.__TAURI__ && typeof window.__TAURI__.invoke === 'function') {
    return window.__TAURI__.invoke(command, payload);
  }
  // 兼容旧版 Tauri 挂载方式
  if (typeof window.invoke === 'function') {
    return window.invoke({ cmd: command, ...payload });
  }
  throw new Error('未检测到 Tauri 运行时，当前页面只能在桌面应用内使用。');
}

async function connect(username, password) {
  try {
    setLoading(true);
    setStatus('正在建立 VPN 连接，请稍候…', 'info');
    const result = await invoke('connect_vpn', { username, password });
    setStatus(result || 'VPN 连接成功，可以访问校园内网资源。', 'success');
  } catch (error) {
    setStatus('连接失败：' + (error?.message || error || '未知错误'), 'error');
  } finally {
    setLoading(false);
  }
}

async function disconnect() {
  try {
    setStatus('正在断开 VPN 连接…', 'info');
    const result = await invoke('disconnect_vpn', {});
    setStatus(result || 'VPN 已断开。', 'success');
  } catch (error) {
    setStatus('断开失败：' + (error?.message || error || '未知错误'), 'error');
  }
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  const username = document.getElementById('username').value.trim();
  const password = document.getElementById('password').value;
  if (!username || !password) {
    setStatus('请输入账号和密码。', 'error');
    return;
  }
  connect(username, password);
});

cancelBtn.addEventListener('click', () => {
  disconnect();
});

document.getElementById('themeToggle').addEventListener('click', toggleTheme);

// 监听系统主题变化
window
  .matchMedia('(prefers-color-scheme: dark)')
  .addEventListener('change', (event) => {
    if (!localStorage.getItem(THEME_KEY)) {
      applyTheme(event.matches ? 'dark' : 'light');
    }
  });

// 初始化
loadTheme();
setStatus('请输入 VPN 账号密码后点击连接。', 'info');
