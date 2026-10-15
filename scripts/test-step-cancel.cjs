const fs = require('node:fs')
const { spawn } = require('node:child_process')

// Cancels a step script the way the GitHub Actions runner does. Each signal
// goes to the step's bash process only. SIGTERM follows 7.5 seconds after
// SIGINT, and SIGKILL follows 2.5 seconds after SIGTERM. The step is spawned
// from Node because a bash parent would start it with SIGINT ignored.
const [stepScript, logFile, readyFile, firstSignal] = process.argv.slice(2)

if (!stepScript || !logFile || !readyFile || !['SIGINT', 'SIGTERM'].includes(firstSignal)) {
  throw new Error('Usage: node test-step-cancel.cjs <step-script> <log-file> <ready-file> <SIGINT|SIGTERM>')
}

const escalation = [
  ['SIGINT', 7500],
  ['SIGTERM', 2500],
  ['SIGKILL', 0],
].slice(firstSignal === 'SIGINT' ? 0 : 1)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const log = fs.openSync(logFile, 'w')
const step = spawn('bash', ['--noprofile', '--norc', '-e', '-o', 'pipefail', stepScript], {
  stdio: ['ignore', log, log],
})
const exited = new Promise((resolve) => {
  step.on('exit', (code, signal) => resolve(code === null ? signal : String(code)))
})

const isReady = () => fs.existsSync(readyFile) && fs.statSync(readyFile).size > 0

async function main() {
  for (let attempt = 0; attempt < 100 && !isReady(); attempt++) {
    await sleep(50)
  }
  if (!isReady()) {
    step.kill('SIGKILL')
    throw new Error('The step did not become ready')
  }

  const sent = []
  for (const [signal, grace] of escalation) {
    step.kill(signal)
    sent.push(signal)
    const exit = await Promise.race([exited, sleep(grace).then(() => null)])
    if (exit !== null) {
      return `sent=${sent.join(',')} exit=${exit}`
    }
  }
  return `sent=${sent.join(',')} exit=${await exited}`
}

// A pending escalation timer would otherwise keep this process alive for the
// rest of its grace period.
main().then(
  (result) => {
    process.stdout.write(`${result}\n`)
    process.exit(0)
  },
  (error) => {
    console.error(error.message)
    process.exit(1)
  },
)
