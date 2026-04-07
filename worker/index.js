/**
 * WallHaven API Proxy - Cloudflare Worker
 *
 * 功能：
 * 1. 代理 wallhaven.cc 的 API 请求（搜索、图片）
 * 2. 处理 CORS，允许来自 macOS app 的请求
 * 3. 缓存响应以减少重复请求
 * 4. 支持搜索 API：/api/search?q={query}&page={page}
 * 5. 支持图片代理：/api/img/{wallpaperId}
 */

// WallHaven API 基础地址
const WALLHAVEN_API = 'https://wallhaven.cc';
const WALLHAVEN_IMG = 'https://w.wallhaven.cc';

// 缓存配置
const CACHE_SEARCH_TTL = 60 * 15;      // 搜索结果缓存 15 分钟
const CACHE_IMAGE_TTL = 60 * 60 * 24;  // 图片缓存 24 小时

// 允许的来源（macOS app）
const ALLOWED_ORIGINS = [
  'app://com.wallhaven.mac',
  'wallhaven-mac://',
  'http://localhost:*',
  'http://127.0.0.1:*',
];

// 超时配置（毫秒）
const FETCH_TIMEOUT = 30000;

/**
 * 创建 CORS 响应头
 */
function getCorsHeaders(origin) {
  // 检查来源是否在允许列表中，或使用通配符
  const allowOrigin = ALLOWED_ORIGINS.some(o =>
    origin === o || o.includes('*')
  ) ? origin : (ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0]);

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Requested-With',
    'Access-Control-Max-Age': '86400',
    'Content-Type': 'application/json; charset=utf-8',
  };
}

/**
 * 创建图片响应头（透传原始类型）
 */
function getImageCorsHeaders(origin, contentType = 'image/jpeg') {
  const allowOrigin = ALLOWED_ORIGINS.some(o =>
    origin === o || o.includes('*')
  ) ? origin : (ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0]);

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Max-Age': '86400',
    'Content-Type': contentType,
    'Cache-Control': `public, max-age=${CACHE_IMAGE_TTL}, immutable`,
  };
}

/**
 * 超时封装的 fetch
 */
async function fetchWithTimeout(url, options, timeout = FETCH_TIMEOUT) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeout);

  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);
    return response;
  } catch (error) {
    clearTimeout(timeoutId);
    if (error.name === 'AbortError') {
      throw new Error(`请求超时: ${url}`);
    }
    throw error;
  }
}

/**
 * 获取缓存对象
 */
async function openCache() {
  return await caches.open('wallhaven-proxy-v1');
}

/**
 * 从缓存获取响应
 */
async function getFromCache(cache, request) {
  const cacheKey = request.url;
  const cached = await cache.match(cacheKey);
  if (cached) {
    console.log(`[Cache HIT] ${cacheKey}`);
    return cached;
  }
  console.log(`[Cache MISS] ${cacheKey}`);
  return null;
}

/**
 * 写入缓存
 */
async function saveToCache(cache, request, response, ttl) {
  const cacheKey = request.url;
  const headers = new Headers(response.headers);
  headers.set('Cache-Control', `public, max-age=${ttl}`);

  const cachedResponse = new Response(await response.clone().text(), {
    status: response.status,
    statusText: response.statusText,
    headers: headers,
  });

  await cache.put(cacheKey, cachedResponse);
  console.log(`[Cache SAVE] ${cacheKey} (TTL: ${ttl}s)`);
}

/**
 * 处理搜索 API 请求
 * GET /api/search?q={query}&page={page}
 */
async function handleSearchRequest(url, cache) {
  const { searchParams } = url;

  // 构建 WallHaven API URL
  const query = searchParams.get('q') || '';
  const page = searchParams.get('page') || '1';
  const perPage = searchParams.get('per_page') || '8';

  // 保留原始查询参数并添加必要参数
  const params = new URLSearchParams({
    q: query,
    page: page,
    per_page: perPage,
  });

  // 可选参数透传
  const optionalParams = ['categories', 'purity', 'sorting', 'order', 'topRange', 'atleast', 'resolutions', 'ratios', 'colors', 'ai'];
  optionalParams.forEach(key => {
    const value = searchParams.get(key);
    if (value) params.set(key, value);
  });

  const targetUrl = `${WALLHAVEN_API}/api/v1/search?${params.toString()}`;
  console.log(`[Search] ${targetUrl}`);

  // 检查缓存
  const cachedResponse = await getFromCache(cache, { url: targetUrl });
  if (cachedResponse) {
    return cachedResponse;
  }

  try {
    const response = await fetchWithTimeout(targetUrl, {
      headers: {
        'User-Agent': 'WallHaven macOS App/1.0',
        'Accept': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`WallHaven API 错误: ${response.status} ${response.statusText}`);
    }

    const data = await response.text();

    // 创建响应
    const resp = new Response(data, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': `public, max-age=${CACHE_SEARCH_TTL}`,
      },
    });

    // 保存到缓存
    await saveToCache(cache, { url: targetUrl }, resp, CACHE_SEARCH_TTL);

    return resp;
  } catch (error) {
    console.error(`[Search Error] ${error.message}`);
    return new Response(JSON.stringify({
      error: true,
      message: error.message,
    }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

/**
 * 处理图片代理请求
 * GET /api/img/{wallpaperId}
 * GET /api/img/{wallpaperId}/{resolution}
 */
async function handleImageProxyRequest(url, cache) {
  const pathParts = url.pathname.split('/').filter(Boolean);
  // pathParts: ['api', 'img', 'wallpaperId', 'resolution?']

  const wallpaperId = pathParts[2];
  const resolution = pathParts[3] || null;

  if (!wallpaperId) {
    return new Response(JSON.stringify({
      error: true,
      message: 'Missing wallpaper ID',
    }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // 确定目标图片 URL
  let targetUrl;
  let contentType = 'image/jpeg';

  if (resolution) {
    // 请求指定分辨率的缩略图
    targetUrl = `${WALLHAVEN_IMG}/small/${resolution}/${wallpaperId}`;
  } else {
    // 请求完整图片
    targetUrl = `${WALLHAVEN_IMG}/full/${wallpaper}/cover`;
  }

  console.log(`[Image Proxy] ${targetUrl}`);

  // 构建缓存 key
  const cacheKey = url.toString();

  // 检查缓存
  const cachedResponse = await getFromCache(cache, { url: cacheKey });
  if (cachedResponse) {
    const headers = new Headers(cachedResponse.headers);
    headers.set('Access-Control-Allow-Origin', '*');
    return new Response(cachedResponse.body, {
      status: cachedResponse.status,
      headers: headers,
    });
  }

  try {
    const response = await fetchWithTimeout(targetUrl, {
      headers: {
        'User-Agent': 'WallHaven macOS App/1.0',
        'Referer': WALLHAVEN_API,
      },
    });

    if (!response.ok) {
      throw new Error(`图片获取失败: ${response.status}`);
    }

    // 获取原始 content-type
    contentType = response.headers.get('Content-Type') || 'image/jpeg';

    const imageBuffer = await response.arrayBuffer();

    // 确定正确的 content-type
    if (contentType.includes('image/jpeg') || targetUrl.endsWith('.jpg') || targetUrl.endsWith('.jpeg')) {
      contentType = 'image/jpeg';
    } else if (contentType.includes('image/png')) {
      contentType = 'image/png';
    } else if (contentType.includes('image/gif')) {
      contentType = 'image/gif';
    } else if (contentType.includes('image/webp')) {
      contentType = 'image/webp';
    }

    // 创建响应
    const resp = new Response(imageBuffer, {
      status: response.status,
      headers: {
        'Content-Type': contentType,
        'Content-Length': imageBuffer.byteLength.toString(),
        'Cache-Control': `public, max-age=${CACHE_IMAGE_TTL}, immutable`,
        'X-Image-Id': wallpaperId,
      },
    });

    // 保存到缓存
    await saveToCache(cache, { url: cacheKey }, resp, CACHE_IMAGE_TTL);

    return resp;
  } catch (error) {
    console.error(`[Image Proxy Error] ${error.message}`);
    return new Response(JSON.stringify({
      error: true,
      message: error.message,
    }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

/**
 * 处理壁纸详情 API
 * GET /api/w/{wallpaperId}
 */
async function handleWallpaperInfoRequest(url, cache) {
  const pathParts = url.pathname.split('/').filter(Boolean);
  const wallpaperId = pathParts[2];

  if (!wallpaperId) {
    return new Response(JSON.stringify({
      error: true,
      message: 'Missing wallpaper ID',
    }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const targetUrl = `${WALLHAVEN_API}/api/v1/w/${wallpaperId}`;
  console.log(`[Wallpaper Info] ${targetUrl}`);

  // 检查缓存
  const cachedResponse = await getFromCache(cache, { url: targetUrl });
  if (cachedResponse) {
    return cachedResponse;
  }

  try {
    const response = await fetchWithTimeout(targetUrl, {
      headers: {
        'User-Agent': 'WallHaven macOS App/1.0',
        'Accept': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`WallHaven API 错误: ${response.status}`);
    }

    const data = await response.text();

    const resp = new Response(data, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': `public, max-age=${CACHE_SEARCH_TTL}`,
      },
    });

    await saveToCache(cache, { url: targetUrl }, resp, CACHE_SEARCH_TTL);

    return resp;
  } catch (error) {
    console.error(`[Wallpaper Info Error] ${error.message}`);
    return new Response(JSON.stringify({
      error: true,
      message: error.message,
    }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

/**
 * 处理收藏/标记 API 请求（需要 API Key）
 * GET /api/favorites?q=...
 */
async function handleFavoritesRequest(url, env, cache) {
  const apiKey = env.WALLHAVEN_API_KEY;

  if (!apiKey) {
    return new Response(JSON.stringify({
      error: true,
      message: 'API key not configured',
    }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const { searchParams } = url;
  const page = searchParams.get('page') || '1';

  const targetUrl = `${WALLHAVEN_API}/api/v1/favorites?apikey=${apiKey}&page=${page}`;
  console.log(`[Favorites] ${targetUrl}`);

  // 检查缓存（用户数据缓存时间短一些）
  const cachedResponse = await getFromCache(cache, { url: targetUrl });
  if (cachedResponse) {
    return cachedResponse;
  }

  try {
    const response = await fetchWithTimeout(targetUrl, {
      headers: {
        'User-Agent': 'WallHaven macOS App/1.0',
        'Accept': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`WallHaven API 错误: ${response.status}`);
    }

    const data = await response.text();

    const resp = new Response(data, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'private, max-age=300', // 用户私有数据，短缓存
      },
    });

    // 不缓存私有数据
    return resp;
  } catch (error) {
    console.error(`[Favorites Error] ${error.message}`);
    return new Response(JSON.stringify({
      error: true,
      message: error.message,
    }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

/**
 * 主处理函数
 */
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin') || '';

    console.log(`[${new Date().toISOString()}] ${request.method} ${url.pathname}`);

    // 打开缓存
    const cache = await openCache();

    // 处理 CORS 预检请求
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: getCorsHeaders(origin),
      });
    }

    // 路由处理
    const path = url.pathname;

    try {
      let response;

      if (path.startsWith('/api/search')) {
        // 搜索 API
        response = await handleSearchRequest(url, cache);
      } else if (path.startsWith('/api/img/')) {
        // 图片代理
        response = await handleImageProxyRequest(url, cache);
      } else if (path.startsWith('/api/w/')) {
        // 壁纸详情
        response = await handleWallpaperInfoRequest(url, cache);
      } else if (path.startsWith('/api/favorites')) {
        // 用户收藏（需要 API Key）
        response = await handleFavoritesRequest(url, env, cache);
      } else if (path === '/api/health') {
        // 健康检查
        return new Response(JSON.stringify({
          status: 'ok',
          timestamp: new Date().toISOString(),
        }), {
          status: 200,
          headers: {
            'Content-Type': 'application/json',
          },
        });
      } else {
        // 未知路由
        return new Response(JSON.stringify({
          error: true,
          message: 'Unknown endpoint',
        }), {
          status: 404,
          headers: {
            'Content-Type': 'application/json',
            ...getCorsHeaders(origin),
          },
        });
      }

      // 添加 CORS 头（如果是 JSON 响应）
      const contentType = response.headers.get('Content-Type') || '';
      if (contentType.includes('application/json')) {
        const headers = new Headers(response.headers);
        Object.entries(getCorsHeaders(origin)).forEach(([key, value]) => {
          headers.set(key, value);
        });
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: headers,
        });
      }

      return response;
    } catch (error) {
      console.error(`[Unhandled Error] ${error.message}`);
      return new Response(JSON.stringify({
        error: true,
        message: 'Internal server error',
      }), {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
          ...getCorsHeaders(origin),
        },
      });
    }
  },
};

/**
 * 环境变量说明（需要在 Cloudflare Worker 设置）：
 *
 * WALLHAVEN_API_KEY - 用户的 WallHaven API Key（可选，用于访问收藏等功能）
 *
 * 路由配置建议：
 * - /api/* - 代理所有 API 请求
 * 或
 * - /search/* - 仅代理搜索
 * - /img/* - 仅代理图片
 */
