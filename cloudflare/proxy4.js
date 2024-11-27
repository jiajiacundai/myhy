// 优化可读性
// 定义配置常量，方便维护和修改
const CONFIG = {
  // 源站和目标站点配置
  SOURCE_DOMAIN: 'ceshi.xinxinran.pp.ua',
  TARGET_DOMAIN: 'lvdou58.sanguoguo.dedyn.io',
  
  // 允许直接传输的响应内容类型
  PASSTHROUGH_CONTENT_TYPES: [
    'text/html', 
    'text/css', 
    'application/javascript',
    'text/javascript'
  ]
};

// 优化请求头处理函数
function getClientIP(request) {
  const ipHeaders = [
    'CF-Connecting-IP', 
    'X-Real-IP', 
    'X-Forwarded-For'
  ];
  
  for (const header of ipHeaders) {
    const ip = request.headers.get(header);
    if (ip) return ip;
  }
  
  return '0.0.0.0';
}

// 创建修改后的请求头
function createModifiedHeaders(request, clientIP) {
  const headers = new Headers(request.headers);
  headers.set('X-Forwarded-For', clientIP);
  headers.set('X-Original-Host', new URL(request.url).host);
  
  return headers;
}

// 处理可修改的文本内容
async function processTextResponse(response, sourceRegex, targetDomain) {
  const text = await response.text();
  const modifiedText = text.replace(sourceRegex, targetDomain);
  
  return new Response(modifiedText, {
    status: response.status,
    headers: response.headers
  });
}

// 主请求处理函数
async function handleRequest(request) {
  try {
    const url = new URL(request.url);
    const sourceRegex = new RegExp(CONFIG.SOURCE_DOMAIN.replace(/\./g, '\\.'), 'g');
    
    // 构建目标URL
    const targetUrl = `https://${CONFIG.TARGET_DOMAIN}${url.pathname}${url.search}`;
    
    // 获取客户端IP
    const clientIP = getClientIP(request);
    
    // 创建修改后的请求头
    const modifiedHeaders = createModifiedHeaders(request, clientIP);
    
    // 创建新的请求
    const modifiedRequest = new Request(targetUrl, {
      method: request.method,
      headers: modifiedHeaders,
      body: ['GET', 'HEAD'].includes(request.method) ? null : request.body,
      redirect: 'manual'
    });
    
    // 发起请求并获取响应
    const response = await fetch(modifiedRequest);
    
    // 检查内容类型
    const contentType = response.headers.get('content-type') || '';
    
    // 根据内容类型处理响应
    if (CONFIG.PASSTHROUGH_CONTENT_TYPES.some(type => contentType.includes(type))) {
      return await processTextResponse(response.clone(), sourceRegex, CONFIG.TARGET_DOMAIN);
    }
    
    // 非文本内容直接返回
    return response;
  
  } catch (error) {
    // 错误处理
    console.error('请求处理错误:', error);
    return new Response('服务器错误', { status: 500 });
  }
}

// 事件监听器
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});
