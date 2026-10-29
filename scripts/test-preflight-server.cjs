const fs = require('node:fs')
const http = require('node:http')

const [readyFile, requestFile, routesFile, logFile] = process.argv.slice(2)

if (!readyFile || !requestFile) {
  throw new Error('Usage: node test-preflight-server.cjs <ready-file> <request-file> [<routes-file> <log-file>]')
}

// Routes map "METHOD /path?query" to { status, body, delayMs } and are read on
// every request so a test can change them between runs.
function findRoute(method, url) {
  if (!routesFile || !fs.existsSync(routesFile)) {
    return undefined
  }
  return JSON.parse(fs.readFileSync(routesFile, 'utf8'))[`${method} ${url}`]
}

const server = http.createServer((request, response) => {
  const chunks = []

  request.on('data', (chunk) => chunks.push(chunk))
  request.on('end', () => {
    const rawBody = Buffer.concat(chunks).toString('utf8')
    const record = {
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: rawBody ? JSON.parse(rawBody) : null,
    }

    if (logFile) {
      fs.appendFileSync(logFile, `${JSON.stringify(record)}\n`)
    }

    if (request.method === 'POST' && request.url === '/next/test-sessions/github-checks/preflight') {
      fs.writeFileSync(requestFile, JSON.stringify(record))
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ available: true, reason: 'available' }))
      return
    }

    const route = findRoute(request.method, request.url) ?? { status: 404, body: { message: 'Not Found' } }
    const timer = setTimeout(() => {
      response.writeHead(route.status ?? 200, { 'content-type': 'application/json' })
      response.end(route.body === undefined ? '' : JSON.stringify(route.body))
    }, route.delayMs ?? 0)
    response.on('close', () => clearTimeout(timer))
  })
})

server.listen(0, '127.0.0.1', () => {
  const address = server.address()
  if (!address || typeof address === 'string') {
    throw new Error('Unable to determine preflight server port')
  }
  fs.writeFileSync(readyFile, String(address.port))
})

process.on('SIGTERM', () => server.close())
