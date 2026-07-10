const fs = require('node:fs')
const http = require('node:http')

const [readyFile, requestFile] = process.argv.slice(2)

if (!readyFile || !requestFile) {
  throw new Error('Usage: node test-preflight-server.cjs <ready-file> <request-file>')
}

const server = http.createServer((request, response) => {
  const chunks = []

  request.on('data', (chunk) => chunks.push(chunk))
  request.on('end', () => {
    const rawBody = Buffer.concat(chunks).toString('utf8')
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: rawBody ? JSON.parse(rawBody) : null,
      }),
    )

    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ available: true, reason: 'available' }))
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
