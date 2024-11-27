// 增加传递真实ip
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);

  // 指定目标反向代理的 URL
  const targetUrl = `https://ceshi.xinxinran.pp.ua${url.pathname}`;

  // 获取客户端的真实 IP
  const clientIp = request.headers.get('CF-Connecting-IP') || request.headers.get('X-Real-IP') || request.headers.get('X-Forwarded-For') || '0.0.0.0';

  // 创建一个新的头对象
  const modifiedHeaders = new Headers(request.headers);
  modifiedHeaders.set('X-Forwarded-For', clientIp);

  // 创建一个新的请求
  const modifiedRequest = new Request(targetUrl, {
    method: request.method,
    headers: modifiedHeaders,
    body: request.body,
    redirect: 'follow'
  });

  // 获取目标服务器的响应
  let response = await fetch(modifiedRequest);

  // 检查响应类型并重写内容
  const contentType = response.headers.get('content-type') || '';
  if (contentType.includes('text/html') || contentType.includes('text/css') || contentType.includes('application/javascript')) {
    // 将响应内容转为文本
    let text = await response.text();

    // 替换内容：例如，将 example.com 替换为 yoursite.com
    text = text.replace(/ceshi.xinxinran\.pp.ua/g, 'lvdou58.xinxinran.pp.ua');

    // 返回修改后的响应
    return new Response(text, {
      status: response.status,
      headers: response.headers
    });
  }

  // 如果不是需要重写的类型，则直接返回原始响应
  return response;
}
