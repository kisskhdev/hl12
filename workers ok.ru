/**
 * Premium Cloudflare Worker - OK.ru Video Stream Extractor & CORS Range Proxy
 * 
 * Features:
 * 1. GET / or empty: Premium Glassmorphic Web UI (in Khmer & English) for interactive extraction.
 * 2. GET /?url=<ok.ru link>: Returns JSON metadata + extracted MP4/M3U8 URLs.
 * 3. GET /proxy?url=<cdn url>: Streams the video file with universal CORS headers & full HTTP Range headers (for seek support).
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. Route to Stream Proxy
    if (url.pathname === '/proxy') {
      return handleProxy(request);
    }

    // 2. Route to JSON API / Extraction
    const targetUrl = url.searchParams.get('url');
    if (targetUrl) {
      return handleExtraction(targetUrl, url);
    }

    // 3. Serve Premium Web Interface
    return serveWebUI(url);
  }
};

/**
 * Handle Stream Proxying
 * Forwards Range headers to CDN and adds universal CORS headers to bypass restrictions.
 */
async function handleProxy(request) {
  // Handle CORS Preflight Requests immediately (Do not forward OPTIONS to OK.ru CDN)
  if (request.method === 'OPTIONS') {
    const requestedHeaders = request.headers.get('Access-Control-Request-Headers') || '*';
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
        'Access-Control-Allow-Headers': requestedHeaders,
        'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges',
        'Access-Control-Max-Age': '86400',
      }
    });
  }

  const url = new URL(request.url);
  const streamUrl = url.searchParams.get('url');

  if (!streamUrl) {
    return new Response(JSON.stringify({ error: 'Missing stream url parameter' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }

  let currentUrl = streamUrl;
  let response;
  let redirectCount = 0;

  // Clone headers to preserve legitimate browser signatures (Sec-Ch-Ua, Accept-Language, etc.)
  // vkuser.net's anti-bot system will return 400 Bad Request if these natural browser headers are completely missing!
  const upstreamHeaders = new Headers(request.headers);
  upstreamHeaders.delete('host');
  upstreamHeaders.delete('origin');
  upstreamHeaders.delete('referer');
  upstreamHeaders.delete('sec-fetch-site');
  upstreamHeaders.delete('sec-fetch-mode');
  upstreamHeaders.delete('sec-fetch-dest');
  
  // CRITICAL FIXES FOR 400 BAD REQUEST & PARSING ERRORS:
  // 1. Never send the user's browser cookies to the upstream CDN
  upstreamHeaders.delete('cookie');
  // 2. Remove Accept-Encoding so Cloudflare automatically decompresses the response
  upstreamHeaders.delete('accept-encoding');

  // FORCE the exact same User-Agent used during extraction (Critical for srcAg/CHROME signature)
  upstreamHeaders.set('user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');
  
  // SPOOF Referer and Origin to bypass OK.ru anti-hotlinking protection!
  // If these are missing, vkuser.net throws 400 Bad Request or 403 Forbidden.
  upstreamHeaders.set('referer', 'https://ok.ru/');
  upstreamHeaders.set('origin', 'https://ok.ru');
  
  // Pre-calculate if this is likely an HLS request based on URL
  const isM3u8Request = url.searchParams.get('ext') === '.m3u8' || (streamUrl && streamUrl.includes('.m3u8'));

  // Forward the Range header ONLY for video/TS files.
  // iOS Safari sometimes sends Range requests for M3U8 files (like bytes=0-1 to sniff), 
  // which causes vkuser.net to throw a 400 Bad Request!
  if (request.headers.has('range') && !isM3u8Request) {
    upstreamHeaders.set('range', request.headers.get('range'));
  } else if (isM3u8Request) {
    upstreamHeaders.delete('range');
  }

  // We only track cookies set by the upstream during redirects
  let currentCookies = '';

  try {
    // Manual redirect loop to preserve Range headers and Cookies (Fix for iOS Safari 224003)
    while (redirectCount < 3) {
      if (currentCookies) {
        upstreamHeaders.set('cookie', currentCookies);
      }

      response = await fetch(currentUrl, {
        method: 'GET', // ALWAYS use GET to prevent upstream from rejecting HEAD probing requests
        headers: upstreamHeaders,
        redirect: 'manual'
      });

      if (response.status >= 300 && response.status < 400 && response.headers.has('location')) {
        // Extract cookies from redirect
        const setCookies = response.headers.get('set-cookie');
        if (setCookies) {
          // Simplistic cookie merge
          const newCookies = setCookies.split(', ').map(c => c.split(';')[0]).join('; ');
          currentCookies = currentCookies ? `${currentCookies}; ${newCookies}` : newCookies;
        }

        // Get next URL
        let location = response.headers.get('location');
        if (location.startsWith('/')) {
          location = new URL(location, currentUrl).toString();
        }
        currentUrl = location;
        redirectCount++;
      } else {
        // Not a redirect, break out
        break;
      }
    }

    // Create response headers with CORS allowed
    const responseHeaders = new Headers(response.headers);
    responseHeaders.set('Access-Control-Allow-Origin', '*');
    responseHeaders.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    responseHeaders.set('Access-Control-Allow-Headers', '*');
    responseHeaders.set('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges');

    // Detect HLS streams more reliably even if the user forgets the ext parameter
    let isHls = url.searchParams.get('ext') === '.m3u8' || (streamUrl && streamUrl.includes('.m3u8'));
    const contentType = response.headers.get('Content-Type') || '';
    if (contentType.includes('mpegurl') || contentType.includes('application/x-mpegurl') || contentType.includes('application/vnd.apple.mpegurl')) {
      isHls = true;
    }

    // Force correct content type if missing to satisfy iOS Safari
    if (!contentType || contentType === 'application/octet-stream') {
      responseHeaders.set('Content-Type', isHls ? 'application/vnd.apple.mpegurl' : 'video/mp4');
    }

    // EXPLICITLY PRESERVE Content-Length for MP4 to prevent Cloudflare from using Transfer-Encoding: chunked (CRITICAL FOR iOS)
    if (!isHls) {
      const contentLength = response.headers.get('Content-Length');
      if (contentLength) {
        responseHeaders.set('Content-Length', contentLength);
      }
    }

    // M3U8 REWRITE LOGIC: Fix relative paths in HLS playlist
    if (isHls && response.status === 200) {
      let m3u8Text = await response.text();
      const baseUrl = new URL(currentUrl);
      
      // Rewrite ALL segment/playlist URLs to route through our proxy to bypass CORS
      const lines = m3u8Text.split('\n');
      let isNextLinePlaylist = false;

      m3u8Text = lines.map(line => {
        const trimmed = line.trim();

        // Track context from tags to smartly determine if the next URL is a playlist or a segment
        if (trimmed.startsWith('#EXT-X-STREAM-INF') || trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
          isNextLinePlaylist = true;
        } else if (trimmed.startsWith('#EXTINF')) {
          isNextLinePlaylist = false;
        }

        if (trimmed && !trimmed.startsWith('#')) {
          const absoluteUrl = trimmed.startsWith('http') ? trimmed : new URL(trimmed, baseUrl.href).href;
          
          // Determine the correct extension based on context or URL content
          let ext = '.mp4'; // fallback for segments
          if (isNextLinePlaylist || absoluteUrl.includes('.m3u8')) {
            ext = '.m3u8';
          } else if (absoluteUrl.includes('.ts')) {
            ext = '.ts';
          }
          
          // Reset context for the next URL
          isNextLinePlaylist = false;

          return `${url.origin}/proxy?url=${encodeURIComponent(absoluteUrl)}&ext=${ext}`;
        }
        
        // Also rewrite URLs inside tags like URI="..." (e.g. for subtitles or keys)
        if (trimmed.startsWith('#') && trimmed.includes('URI="')) {
          return trimmed.replace(/URI="([^"]+)"/, (match, p1) => {
            const absoluteUrl = p1.startsWith('http') ? p1 : new URL(p1, baseUrl.href).href;
            const ext = absoluteUrl.includes('.m3u8') ? '.m3u8' : '.mp4';
            return `URI="${url.origin}/proxy?url=${encodeURIComponent(absoluteUrl)}&ext=${ext}"`;
          });
        }
        
        return line;
      }).join('\n');

      return new Response(m3u8Text, {
        status: 200,
        headers: responseHeaders
      });
    }

    // For MP4 or non-200 responses, stream normally
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: 'Proxy failed: ' + err.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }
}

/**
 * Handle OK.ru Link Extraction and JSON Response
 */
async function handleExtraction(targetUrl, workerUrl) {
  try {
    // Force HTTPS to prevent Mixed Content errors (database may store http:// links)
    targetUrl = targetUrl.replace(/^http:\/\//i, 'https://');
    
    const data = await extractOkRu(targetUrl);
    
    // Enrich streams with proxy URLs, appending proper extensions for strict iOS Safari compatibility
    data.streams = data.streams.map(stream => {
      const ext = stream.qualityName === 'hls' ? '.m3u8' : '.mp4';
      const proxyUrl = `${workerUrl.origin}/proxy?url=${encodeURIComponent(stream.url)}&ext=${ext}`;
      return {
        ...stream,
        proxyUrl: proxyUrl
      };
    });

    return new Response(JSON.stringify({ success: true, ...data }), {
      status: 200,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*'
      }
    });
  } catch (err) {
    return new Response(JSON.stringify({ success: false, error: err.message }), {
      status: 400,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*'
      }
    });
  }
}

/**
 * OK.ru Video Extraction Core Logic
 */
async function extractOkRu(url) {
  // Extract video ID
  const okRuRegex = /(?:ok\.ru|odnoklassniki\.ru)\/(?:videoembed|video)\/(\d+)/i;
  const match = url.match(okRuRegex);
  if (!match) {
    throw new Error('តំណភ្ជាប់ OK.ru មិនត្រឹមត្រូវទេ! (Invalid OK.ru link)');
  }
  const videoId = match[1];

  // Headers ដែលធ្វើក្លែងក្លាយជា Browser ពិតប្រាកដ (Spoof real browser request to bypass 400)
  const browserHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate, br',
    'Referer': 'https://ok.ru/',
    'Origin': 'https://ok.ru',
    'Sec-Fetch-Dest': 'iframe',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Ch-Ua': '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
    'Sec-Ch-Ua-Mobile': '?0',
    'Sec-Ch-Ua-Platform': '"Windows"',
    'Upgrade-Insecure-Requests': '1',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  // ព្យាយាម Embed URL ជាមុនសិន (Try embed URL first)
  const embedUrl = `https://ok.ru/videoembed/${videoId}`;
  let response = await fetch(embedUrl, { headers: browserHeaders });

  // បើ Embed URL បរាជ័យ → ប្រើ Video page ធម្មតាជំនួស (Fallback to regular video page)
  if (!response.ok) {
    const fallbackUrl = `https://ok.ru/video/${videoId}`;
    response = await fetch(fallbackUrl, {
      headers: { ...browserHeaders, 'Sec-Fetch-Dest': 'document', 'Referer': 'https://ok.ru/' }
    });
  }

  if (!response.ok) {
    throw new Error(`មិនអាចទាញយកទិន្នន័យពី OK.ru បានទេ — HTTP ${response.status}។ វីដេអូអាចជា Private ឬ Geo-Restricted (Could not fetch from OK.ru — HTTP ${response.status}. Video may be private or geo-restricted).`);
  }

  const html = await response.text();

  // Search for data-options attribute
  let dataOptionsStr = null;
  const match1 = html.match(/data-options="([^"]+)"/);
  if (match1) {
    dataOptionsStr = match1[1];
  } else {
    const match2 = html.match(/data-options='([^']+)'/);
    if (match2) {
      dataOptionsStr = match2[1];
    }
  }

  if (!dataOptionsStr) {
    throw new Error(' (Could not find video options in HTML)');
  }

  // Decode HTML entities
  const decoded = decodeEntities(dataOptionsStr);
  const parsed = JSON.parse(decoded);

  let flashvars = parsed.flashvars;
  if (typeof flashvars === 'string') {
    flashvars = JSON.parse(flashvars);
  }

  let metadata = flashvars.metadata;
  if (typeof metadata === 'string') {
    metadata = JSON.parse(metadata);
  }

  if (!metadata || !metadata.videos) {
    throw new Error('មិនមានវីដេអូសម្រាប់ទាញយកទេ (No streaming videos found in metadata)');
  }

  const movie = metadata.movie || {};
  
  // Quality translations for clean display
  const qualityMap = {
    'mobile': '144p (Mobile)',
    'lowest': '240p (Lowest)',
    'low': '360p (Low)',
    'sd': '480p (SD)',
    'hd': '720p (HD)',
    'full': '1080p (Full HD)'
  };

  const videoStreams = metadata.videos.map(v => {
    return {
      qualityName: v.name,
      label: qualityMap[v.name] || v.name.toUpperCase(),
      url: v.url
    };
  });

  // Extract HLS stream for flawless iOS Safari playback (bypasses Range proxy issues)
  if (metadata.hlsManifestUrl) {
    videoStreams.unshift({
      qualityName: 'hls',
      label: 'Auto (HLS)',
      url: metadata.hlsManifestUrl
    });
  }

  return {
    id: videoId,
    title: movie.title || `OK.ru Video ${videoId}`,
    thumbnail: movie.poster || null,
    duration: movie.duration || 0, // in seconds
    streams: videoStreams
  };
}

/**
 * Decode common HTML entities
 */
function decodeEntities(str) {
  return str
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'");
}

/**
 * Premium glassmorphic Web UI in Khmer and English
 */
function serveWebUI(workerUrl) {
  const html = `<!DOCTYPE html>
<html lang="km">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OK.ru Video Link Extractor & Proxy</title>
  
  <!-- Modern Fonts -->
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&family=Kantumruy+Pro:wght@300;400;600;700&display=swap" rel="stylesheet">
  
  <!-- FontAwesome Icons -->
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">

  <style>
    :root {
      --bg-gradient: radial-gradient(circle at 50% 50%, #1e1b4b 0%, #0f0c1b 100%);
      --card-bg: rgba(255, 255, 255, 0.04);
      --card-border: rgba(255, 255, 255, 0.08);
      --glow-color: #6366f1;
      --primary: #818cf8;
      --secondary: #a78bfa;
      --success: #34d399;
      --error: #f87171;
      --text: #f3f4f6;
      --text-muted: #9ca3af;
      
      font-family: 'Outfit', 'Kantumruy Pro', sans-serif;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      background: var(--bg-gradient);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 20px;
      overflow-x: hidden;
      display: none;
    }

    .background-glow {
      position: absolute;
      width: 600px;
      height: 600px;
      background: radial-gradient(circle, rgba(99, 102, 241, 0.15) 0%, rgba(0,0,0,0) 70%);
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      z-index: -1;
      pointer-events: none;
    }

    .container {
      width: 100%;
      max-width: 800px;
      z-index: 1;
    }

    /* Premium Header */
    header {
      text-align: center;
      margin-bottom: 40px;
      animation: fadeInDown 0.8s ease-out;
    }

    header h1 {
      font-size: 2.8rem;
      font-weight: 800;
      background: linear-gradient(135deg, #c084fc 0%, #818cf8 50%, #6366f1 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      margin-bottom: 12px;
      letter-spacing: -0.5px;
    }

    header p {
      color: var(--text-muted);
      font-size: 1.1rem;
      font-weight: 300;
    }

    /* Glassmorphism Main Card */
    .glass-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 24px;
      padding: 40px;
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      box-shadow: 0 20px 50px rgba(0, 0, 0, 0.3);
      animation: fadeInUp 0.8s ease-out;
      margin-bottom: 30px;
    }

    /* Form Styles */
    .input-group {
      position: relative;
      margin-bottom: 25px;
    }

    .input-group input {
      width: 100%;
      padding: 18px 24px;
      background: rgba(255, 255, 255, 0.03);
      border: 2px solid var(--card-border);
      border-radius: 16px;
      color: var(--text);
      font-size: 1rem;
      font-family: inherit;
      outline: none;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    }

    .input-group input:focus {
      border-color: var(--primary);
      box-shadow: 0 0 20px rgba(99, 102, 241, 0.25);
      background: rgba(255, 255, 255, 0.06);
    }

    .input-group label {
      position: absolute;
      left: 20px;
      top: 50%;
      transform: translateY(-50%);
      color: var(--text-muted);
      pointer-events: none;
      transition: all 0.3s ease;
      font-size: 0.95rem;
    }

    .input-group input:focus ~ label,
    .input-group input:not(:placeholder-shown) ~ label {
      top: -10px;
      left: 15px;
      font-size: 0.8rem;
      padding: 0 10px;
      background: #110d21;
      color: var(--primary);
      border-radius: 4px;
    }

    .btn-extract {
      width: 100%;
      padding: 16px;
      background: linear-gradient(135deg, #818cf8 0%, #6366f1 100%);
      border: none;
      border-radius: 16px;
      color: white;
      font-size: 1.1rem;
      font-weight: 600;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 12px;
      transition: all 0.3s ease;
      box-shadow: 0 10px 20px rgba(99, 102, 241, 0.2);
    }

    .btn-extract:hover {
      transform: translateY(-2px);
      box-shadow: 0 15px 25px rgba(99, 102, 241, 0.4);
      background: linear-gradient(135deg, #93c5fd 0%, #818cf8 100%);
    }

    .btn-extract:active {
      transform: translateY(1px);
    }

    /* Loader Styles */
    .loader-container {
      display: none;
      flex-direction: column;
      align-items: center;
      margin: 30px 0;
      gap: 15px;
    }

    .spinner {
      width: 50px;
      height: 50px;
      border: 4px solid rgba(255, 255, 255, 0.05);
      border-top-color: var(--primary);
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    .loader-text {
      color: var(--text-muted);
      font-size: 0.95rem;
    }

    /* Result Panel */
    .result-container {
      display: none;
      animation: fadeIn 0.5s ease-out;
    }

    .video-info {
      display: flex;
      gap: 25px;
      margin-bottom: 30px;
      background: rgba(255, 255, 255, 0.02);
      padding: 20px;
      border-radius: 18px;
      border: 1px solid rgba(255, 255, 255, 0.05);
    }

    .video-thumbnail {
      width: 160px;
      height: 100px;
      border-radius: 12px;
      object-fit: cover;
      box-shadow: 0 8px 16px rgba(0,0,0,0.3);
      border: 1px solid rgba(255,255,255,0.1);
    }

    .video-details {
      display: flex;
      flex-direction: column;
      justify-content: center;
      gap: 6px;
    }

    .video-title {
      font-size: 1.25rem;
      font-weight: 600;
      color: var(--text);
    }

    .video-duration {
      font-size: 0.9rem;
      color: var(--text-muted);
    }

    .video-id {
      font-size: 0.85rem;
      color: var(--primary);
      font-family: monospace;
    }

    /* Streams Table */
    .streams-title {
      font-size: 1.15rem;
      font-weight: 600;
      margin-bottom: 15px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .streams-list {
      display: flex;
      flex-direction: column;
      gap: 15px;
    }

    .stream-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 16px 20px;
      background: rgba(255, 255, 255, 0.03);
      border: 1px solid rgba(255, 255, 255, 0.05);
      border-radius: 16px;
      transition: all 0.3s ease;
    }

    .stream-row:hover {
      background: rgba(255, 255, 255, 0.05);
      border-color: rgba(99, 102, 241, 0.2);
      transform: translateX(5px);
    }

    .stream-label {
      font-weight: 600;
      font-size: 0.95rem;
      color: var(--secondary);
    }

    .stream-actions {
      display: flex;
      gap: 10px;
    }

    .btn-action {
      padding: 10px 16px;
      border-radius: 10px;
      border: none;
      font-weight: 600;
      font-size: 0.85rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 6px;
      transition: all 0.2s ease;
      text-decoration: none;
    }

    .btn-play {
      background: rgba(99, 102, 241, 0.15);
      color: var(--primary);
      border: 1px solid rgba(99, 102, 241, 0.3);
    }

    .btn-play:hover {
      background: var(--primary);
      color: white;
    }

    .btn-copy {
      background: rgba(255, 255, 255, 0.05);
      color: var(--text);
      border: 1px solid rgba(255, 255, 255, 0.1);
    }

    .btn-copy:hover {
      background: rgba(255, 255, 255, 0.15);
    }

    /* Error Banner */
    .error-banner {
      display: none;
      background: rgba(248, 113, 113, 0.1);
      border: 1px solid rgba(248, 113, 113, 0.3);
      padding: 16px 20px;
      border-radius: 14px;
      color: var(--error);
      font-size: 0.95rem;
      align-items: center;
      gap: 12px;
      margin-bottom: 25px;
      animation: shake 0.5s ease-in-out;
    }

    /* Guide Section */
    .guide-card {
      background: rgba(255, 255, 255, 0.02);
      border: 1px solid rgba(255, 255, 255, 0.04);
      border-radius: 20px;
      padding: 25px;
      margin-top: 30px;
    }

    .guide-card h3 {
      font-size: 1.1rem;
      font-weight: 600;
      margin-bottom: 12px;
      color: var(--secondary);
    }

    .guide-list {
      list-style-type: none;
      font-size: 0.9rem;
      color: var(--text-muted);
      display: flex;
      flex-direction: column;
      gap: 10px;
    }

    .guide-list li {
      display: flex;
      align-items: flex-start;
      gap: 10px;
    }

    .guide-list i {
      color: var(--primary);
      margin-top: 3px;
    }

    /* API Endpoint Tip */
    .api-tip {
      font-size: 0.85rem;
      color: var(--text-muted);
      margin-top: 25px;
      text-align: center;
      background: rgba(255,255,255,0.02);
      padding: 12px;
      border-radius: 12px;
      border: 1px solid rgba(255,255,255,0.03);
    }

    .api-tip code {
      background: rgba(0,0,0,0.3);
      padding: 3px 6px;
      border-radius: 6px;
      color: var(--secondary);
      font-family: monospace;
    }

    /* Animations */
    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    @keyframes fadeIn {
      from { opacity: 0; }
      to { opacity: 1; }
    }

    @keyframes fadeInUp {
      from {
        opacity: 0;
        transform: translateY(20px);
      }
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }

    @keyframes fadeInDown {
      from {
        opacity: 0;
        transform: translateY(-20px);
      }
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }

    @keyframes shake {
      0%, 100% { transform: translateX(0); }
      20%, 60% { transform: translateX(-6px); }
      40%, 80% { transform: translateX(6px); }
    }

    /* Player Overlay */
    .player-overlay {
      display: none;
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: rgba(0,0,0,0.95);
      z-index: 100;
      align-items: center;
      justify-content: center;
    }

    .player-content {
      width: 90%;
      max-width: 900px;
      aspect-ratio: 16/9;
      background: black;
      border-radius: 16px;
      overflow: hidden;
      position: relative;
      box-shadow: 0 25px 50px rgba(0,0,0,0.5);
    }

    .player-close {
      position: absolute;
      top: 20px;
      right: 20px;
      color: white;
      font-size: 2rem;
      cursor: pointer;
      z-index: 101;
      transition: transform 0.2s ease;
    }

    .player-close:hover {
      transform: scale(1.1);
    }

    video {
      width: 100%;
      height: 100%;
    }

    /* Responsive */
    @media (max-width: 600px) {
      header h1 {
        font-size: 2rem;
      }
      .glass-card {
        padding: 25px 20px;
      }
      .video-info {
        flex-direction: column;
        align-items: center;
        text-align: center;
      }
      .stream-row {
        flex-direction: column;
        gap: 15px;
        align-items: flex-start;
      }
      .stream-actions {
        width: 100%;
      }
      .btn-action {
        flex: 1;
        justify-content: center;
      }
    }
  </style>
</head>
<body>

  <div class="background-glow"></div>

  <div class="container">
    <header>
      <h1>OK.ru Extractor & Proxy</h1>
      <p>ទាញយកតំណភ្ជាប់វីដេអូ MP4 ផ្ទាល់ ជាមួយ range proxy និង CORS គ្មានដែនកំណត់</p>
    </header>

    <div class="glass-card">
      
      <!-- Error Banner -->
      <div class="error-banner" id="errorBanner">
        <i class="fa-solid fa-triangle-exclamation"></i>
        <span id="errorMessage">តំណភ្ជាប់មិនត្រឹមត្រូវ!</span>
      </div>

      <!-- Main Input Form -->
      <div class="input-group">
        <input type="text" id="okUrlInput" placeholder=" " autocomplete="off">
        <label for="okUrlInput"><i class="fa-solid fa-link" style="margin-right: 8px;"></i> បញ្ចូលតំណភ្ជាប់ OK.ru (Paste OK.ru URL)</label>
      </div>

      <button class="btn-extract" id="extractBtn">
        <i class="fa-solid fa-wand-magic-sparkles"></i>
        <span>ទាញយកតំណភ្ជាប់ (Extract Video)</span>
      </button>

      <!-- Loader -->
      <div class="loader-container" id="loader">
        <div class="spinner"></div>
        <div class="loader-text">កំពុងវិភាគវីដេអូ សូមរង់ចាំ... (Analyzing video...)</div>
      </div>

      <!-- Result Section -->
      <div class="result-container" id="resultSection">
        <div class="video-info">
          <img id="videoThumb" src="" class="video-thumbnail" alt="Thumbnail">
          <div class="video-details">
            <div class="video-title" id="videoTitle">ចំណងជើងវីដេអូ</div>
            <div class="video-duration" id="videoDuration">រយៈពេល: 00:00</div>
            <div class="video-id" id="videoId">ID: -</div>
          </div>
        </div>

        <div class="streams-title">
          <i class="fa-solid fa-play" style="color: var(--secondary)"></i>
          <span>តំណភ្ជាប់វីដេអូដែលរកឃើញ (Direct Streaming Streams)</span>
        </div>

        <div class="streams-list" id="streamsList">
          <!-- Rows will be injected dynamically -->
        </div>
      </div>

      <!-- Guide card -->
      <div class="guide-card">
        <h3><i class="fa-solid fa-circle-info"></i> ការណែនាំអំពីការប្រើប្រាស់ (Developer Guide)</h3>
        <ul class="guide-list">
          <li>
            <i class="fa-solid fa-circle-check"></i>
            <span><strong>CORS & HTTP Range Proxy:</strong> រាល់តំណភ្ជាប់ proxy stream ទាំងអស់គាំទ្រការ Play នៅលើ HTML5 standard players (ដូចជា jwplayer, plyr, video-js) ដោយមិនជាប់ CORS និងអាចអូសស្វែងរក (seek/scrub) បានពេញលេញ។</span>
          </li>
          <li>
            <i class="fa-solid fa-circle-check"></i>
            <span><strong>API Integration:</strong> អ្នកអាចប្រើប្រាស់ API endpoint នេះនៅក្នុង movies app ឬ backend script របស់អ្នកផ្ទាល់។</span>
          </li>
        </ul>
      </div>

      <!-- API tip -->
      <div class="api-tip">
        <i class="fa-solid fa-terminal"></i> API Endpoint: <code>?url={YOUR_OKRU_LINK}</code>
      </div>

    </div>
  </div>

  <!-- Player Modal -->
  <div class="player-overlay" id="playerOverlay">
    <div class="player-close" id="playerClose"><i class="fa-solid fa-xmark"></i></div>
    <div class="player-content">
      <video id="htmlVideoPlayer" controls autoplay></video>
    </div>
  </div>

  <script>
    const extractBtn = document.getElementById('extractBtn');
    const okUrlInput = document.getElementById('okUrlInput');
    const loader = document.getElementById('loader');
    const resultSection = document.getElementById('resultSection');
    const errorBanner = document.getElementById('errorBanner');
    const errorMessage = document.getElementById('errorMessage');
    
    // Result elements
    const videoThumb = document.getElementById('videoThumb');
    const videoTitle = document.getElementById('videoTitle');
    const videoDuration = document.getElementById('videoDuration');
    const videoId = document.getElementById('videoId');
    const streamsList = document.getElementById('streamsList');

    // Video Player Elements
    const playerOverlay = document.getElementById('playerOverlay');
    const playerClose = document.getElementById('playerClose');
    const htmlVideoPlayer = document.getElementById('htmlVideoPlayer');

    // Handle extraction
    extractBtn.addEventListener('click', async () => {
      const url = okUrlInput.value.trim();
      
      if (!url) {
        showError('សូមបញ្ចូលតំណភ្ជាប់ OK.ru ជាមុនសិន! (Please paste an OK.ru URL first!)');
        return;
      }

      hideError();
      hideResults();
      showLoader();

      try {
        const response = await fetch(\`?url=\${encodeURIComponent(url)}\`);
        const data = await response.json();

        if (!data.success) {
          throw new Error(data.error || 'មានបញ្ហាក្នុងការវិភាគតំណភ្ជាប់ (Failed to parse URL)');
        }

        displayResults(data);
      } catch (err) {
        showError(err.message);
      } finally {
        hideLoader();
      }
    });

    // Helper functions
    function showLoader() { loader.style.display = 'flex'; extractBtn.disabled = true; }
    function hideLoader() { loader.style.display = 'none'; extractBtn.disabled = false; }
    
    function showError(msg) {
      errorMessage.textContent = msg;
      errorBanner.style.display = 'flex';
    }
    
    function hideError() {
      errorBanner.style.display = 'none';
    }

    function hideResults() {
      resultSection.style.display = 'none';
    }

    function formatDuration(seconds) {
      if (!seconds) return 'N/A';
      const hrs = Math.floor(seconds / 3600);
      const mins = Math.floor((seconds % 3600) / 60);
      const secs = seconds % 60;
      return [
        hrs > 0 ? hrs : null,
        mins.toString().padStart(2, '0'),
        secs.toString().padStart(2, '0')
      ].filter(x => x !== null).join(':');
    }

    function displayResults(data) {
      videoThumb.src = data.thumbnail || 'https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?w=400';
      videoTitle.textContent = data.title;
      videoDuration.textContent = 'រយៈពេល (Duration): ' + formatDuration(data.duration);
      videoId.textContent = 'Video ID: ' + data.id;

      // Clear existing streams
      streamsList.innerHTML = '';

      // Populate streams
      data.streams.forEach(stream => {
        const row = document.createElement('div');
        row.className = 'stream-row';

        row.innerHTML = \`
          <div class="stream-label">
            <i class="fa-solid fa-film"></i> \${stream.label}
          </div>
          <div class="stream-actions">
            <button class="btn-action btn-play" onclick="playVideo('\${stream.proxyUrl}')">
              <i class="fa-solid fa-circle-play"></i> Play (CORS)
            </button>
            <button class="btn-action btn-copy" onclick="copyToClipboard(this, '\${stream.proxyUrl}')">
              <i class="fa-solid fa-copy"></i> Copy Proxy URL
            </button>
          </div>
        \`;
        
        streamsList.appendChild(row);
      });

      resultSection.style.display = 'block';
      resultSection.scrollIntoView({ behavior: 'smooth' });
    }

    // Video Play logic
    window.playVideo = function(url) {
      htmlVideoPlayer.src = url;
      playerOverlay.style.display = 'flex';
    };

    playerClose.addEventListener('click', () => {
      playerOverlay.style.display = 'none';
      htmlVideoPlayer.pause();
      htmlVideoPlayer.src = '';
    });

    // Copy to clipboard with success feedback micro-animation
    window.copyToClipboard = function(btn, text) {
      navigator.clipboard.writeText(text).then(() => {
        const originalText = btn.innerHTML;
        btn.innerHTML = '<i class="fa-solid fa-check" style="color: var(--success)"></i> Copied!';
        btn.style.borderColor = 'var(--success)';
        
        setTimeout(() => {
          btn.innerHTML = originalText;
          btn.style.borderColor = '';
        }, 2000);
      });
    };
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  });
}
