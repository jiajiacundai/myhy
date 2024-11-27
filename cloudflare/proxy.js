addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});
 
async function handleRequest(request) {
  const url = new URL(request.url);
 
  // 指定目标反向代理的 URL
  const targetUrl = `https://example.com${url.pathname}`;
 
  // 创建一个新的请求
  const modifiedRequest = new Request(targetUrl, {
    method: request.method,
    headers: request.headers,
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
    text = text.replace(/example\.com/g, 'yoursite.com');
 
    // 返回修改后的响应
    return new Response(text, {
      status: response.status,
      headers: response.headers
    });
  }
 
  // 如果不是需要重写的类型，则直接返回原始响应
  return response;
}
