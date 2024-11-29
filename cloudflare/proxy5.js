// 增加安全头，增加压缩优化，增加使用缓存键 cacheKey
const TARGET_DOMAIN = 'https://yingshi.xinxinran.pp.ua';
const REPLACEMENT_DOMAIN = 'lvdou66.sanguoguo.dedyn.io';
const CACHE_TTL = 3600; // 缓存时间 1小时
const TIMEOUT = 10000; // 请求超时时间 10秒

const cache = caches.default;

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request, event));
});

async function handleRequest(request, event) {
  try {
    if (!['GET', 'POST', 'HEAD'].includes(request.method)) {
      return new Response('Method Not Allowed', { status: 405 });
    }

    const url = new URL(request.url);
    const targetUrl = `${TARGET_DOMAIN}${url.pathname}${url.search}`;

    const cacheKey = new Request(request.url, { headers: request.headers });
    const cachedResponse = await cache.match(cacheKey);
    if (cachedResponse) return cachedResponse;

    const clientIp = request.headers.get('CF-Connecting-IP') || 
                     request.headers.get('X-Real-IP') || 
                     request.headers.get('X-Forwarded-For') || 
                     '0.0.0.0';

    const modifiedHeaders = new Headers(request.headers);
    modifiedHeaders.set('X-Forwarded-For', clientIp);
    modifiedHeaders.set('X-Original-Host', url.hostname);

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), TIMEOUT);

    const modifiedRequest = new Request(targetUrl, {
      method: request.method,
      headers: modifiedHeaders,
      body: ['GET', 'HEAD'].includes(request.method) ? null : request.body,
      redirect: 'manual',
      signal: controller.signal,
    });

    const response = await fetch(modifiedRequest);
    clearTimeout(timeoutId);

    const contentType = response.headers.get('content-type') || '';
    const responseClone = response.clone();

    let finalResponse;
    if (['text/html', 'text/css', 'application/javascript'].some(type => contentType.includes(type))) {
      const text = await responseClone.text();
      const modifiedText = text
        .replace(new RegExp(TARGET_DOMAIN.replace(/\./g, '\\.'), 'g'), REPLACEMENT_DOMAIN);
      finalResponse = new Response(modifiedText, { status: response.status, headers: response.headers });
    } else {
      finalResponse = responseClone;
    }

    if (response.status === 200 && contentType.includes('text')) {
      event.waitUntil(cache.put(cacheKey, finalResponse.clone()));
    }

    return addSecurityHeaders(finalResponse);

  } catch (error) {
    console.error('Proxy Error:', error);
    return new Response(`Proxy Error: ${error.message}`, { 
      status: 500,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
}

function addSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('X-Frame-Options', 'SAMEORIGIN');
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  headers.set('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');
  headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  return new Response(response.body, {
    status: response.status,
    headers,
  });
}
