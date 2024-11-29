// 增加缓存，可选的安全头部设置，优化域名替换

// 配置常量
const TARGET_DOMAIN = 'https://yingshi.xinxinran.pp.ua';
const REPLACEMENT_DOMAIN = 'lvdou66.sanguoguo.dedyn.io';
const CACHE_TTL = 60 * 60; // 缓存时间 1小时
const TIMEOUT = 10000; // 请求超时时间 10秒

// 缓存对象
const cache = caches.default;

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request, event));
});

async function handleRequest(request, event) {
  try {
    // 创建 URL 对象
    const url = new URL(request.url);
    const targetUrl = `${TARGET_DOMAIN}${url.pathname}${url.search}`;

    // 尝试从缓存获取响应
    const cachedResponse = await cache.match(request);
    if (cachedResponse) {
      return cachedResponse;
    }

    // 获取客户端真实 IP
    const clientIp = request.headers.get('CF-Connecting-IP') || 
                     request.headers.get('X-Real-IP') || 
                     request.headers.get('X-Forwarded-For') || 
                     '0.0.0.0';

    // 创建修改后的请求头
    const modifiedHeaders = new Headers(request.headers);
    modifiedHeaders.set('X-Forwarded-For', clientIp);
    modifiedHeaders.set('X-Original-Host', url.hostname);

    // 创建带超时的请求
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), TIMEOUT);

    const modifiedRequest = new Request(targetUrl, {
      method: request.method,
      headers: modifiedHeaders,
      body: ['GET', 'HEAD'].includes(request.method) ? null : request.body,
      redirect: 'manual',
      signal: controller.signal
    });

    // 发起请求
    const response = await fetch(modifiedRequest);
    clearTimeout(timeoutId);

    // 克隆响应
    const responseClone = response.clone();

    // 检查内容类型
    const contentType = response.headers.get('content-type') || '';

    let finalResponse;
    if (contentType.includes('text/html') || 
        contentType.includes('text/css') || 
        contentType.includes('application/javascript')) {
      // 处理文本内容
      const text = await responseClone.text();
      const modifiedText = text
        .replace(new RegExp(TARGET_DOMAIN.replace(/\./g, '\\.'), 'g'), REPLACEMENT_DOMAIN)
        .replace(new RegExp('https?://' + TARGET_DOMAIN.replace(/\./g, '\\.'), 'g'), `https://${REPLACEMENT_DOMAIN}`);

      finalResponse = new Response(modifiedText, {
        status: response.status,
        headers: response.headers
      });
    } else {
      // 非文本内容直接返回
      finalResponse = responseClone;
    }

    // 对可缓存的响应进行缓存
    if (response.status === 200 && 
        ['text/html', 'text/css', 'application/javascript'].some(type => contentType.includes(type))) {
      const responseToCache = finalResponse.clone();
      
      // 使用 event.waitUntil 来处理异步缓存操作
      if (event) {
        event.waitUntil(
          cache.put(request, responseToCache)
        );
      }
    }

    return finalResponse;

  } catch (error) {
    // 错误处理
    return new Response(`Proxy Error: ${error.message}`, { 
      status: 500,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
}

// 可选：添加性能和安全的响应头
function addSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('X-Frame-Options', 'DENY');
  headers.set('Referrer-Policy', 'no-referrer');
  headers.set('X-XSS-Protection', '1; mode=block');
  return new Response(response.body, {
    status: response.status,
    headers: headers
  });
}
