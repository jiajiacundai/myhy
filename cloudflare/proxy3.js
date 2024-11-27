// 增加请求类型
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);

  // 指定目标反向代理的 URL
  const targetUrl = `https://ceshi.xinxinran.pp.ua${url.pathname}${url.search}`;

  // 获取客户端的真实 IP
  const clientIp = request.headers.get('CF-Connecting-IP') || request.headers.get('X-Real-IP') || request.headers.get('X-Forwarded-For') || '0.0.0.0';

  // 创建一个新的头对象
  const modifiedHeaders = new Headers(request.headers);
  modifiedHeaders.set('X-Forwarded-For', clientIp);

  // 创建一个新的请求
  const modifiedRequest = new Request(targetUrl, {
    method: request.method,
    headers: modifiedHeaders,
    body: request.method !== 'GET' && request.method !== 'HEAD' ? request.body : null, // Only include body for relevant methods
    redirect: 'manual' // Prevent automatic redirects
  });

  // 获取目标服务器的响应
  const response = await fetch(modifiedRequest);

  // 克隆响应以避免流被消耗
  const responseClone = response.clone();

  // 检查响应的内容类型
  const contentType = response.headers.get('content-type') || '';

  if (contentType.includes('text/html') || contentType.includes('text/css') || contentType.includes('application/javascript')) {
    // 如果是可修改的文本类型，处理内容
    const text = await responseClone.text();
    const modifiedText = text.replace(/ceshi.xinxinran\.pp.ua/g, 'lvdou58.sanguoguo.dedyn.io');

    return new Response(modifiedText, {
      status: response.status,
      headers: response.headers
    });
  } else {
    // 对于非文本内容，直接返回原始响应
    return responseClone;
  }
}
