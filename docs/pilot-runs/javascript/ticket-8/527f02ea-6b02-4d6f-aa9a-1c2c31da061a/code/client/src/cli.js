#!/usr/bin/env node
'use strict';

const { resolveConfig } = require('./config');
const push = require('./push');
const pull = require('./pull');

const COMMANDS = ['push', 'pull', 'sync', 'status'];

async function main() {
  const argv = process.argv.slice(2);
  const command = argv[0];

  if (!command || !COMMANDS.includes(command)) {
    console.error(`syncbox: expected a command, one of: ${COMMANDS.join(', ')} (got '${command ?? ''}')`);
    process.exitCode = 1;
    return;
  }

  let config;
  try {
    config = resolveConfig(argv.slice(1), process.env);
  } catch (err) {
    console.error(`syncbox: ${err.message}`);
    process.exitCode = 1;
    return;
  }

  if (command === 'push') {
    try {
      const result = await push.run(config);
      for (const key of result.uploaded) {
        console.log(`uploaded ${key}`);
      }
      console.log(`push complete: ${result.uploaded.length} uploaded, ${result.skipped.length} unchanged`);
    } catch (err) {
      console.error(`syncbox: push failed: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  if (command === 'pull') {
    try {
      const result = await pull.run(config);
      for (const key of result.downloaded) {
        console.log(`downloaded ${key}`);
      }
      console.log(`pull complete: ${result.downloaded.length} downloaded, ${result.skipped.length} unchanged`);
    } catch (err) {
      console.error(`syncbox: pull failed: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  console.error(`syncbox: '${command}' is not implemented yet`);
  process.exitCode = 1;
}

main();
