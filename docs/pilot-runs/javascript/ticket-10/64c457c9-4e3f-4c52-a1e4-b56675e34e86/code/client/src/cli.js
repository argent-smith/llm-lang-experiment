#!/usr/bin/env node
'use strict';

const { resolveConfig } = require('./config');
const push = require('./push');
const pull = require('./pull');
const sync = require('./sync');
const status = require('./status');

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

  if (command === 'sync') {
    try {
      const result = await sync.run(config);
      for (const key of result.uploaded) {
        console.log(`uploaded ${key}`);
      }
      for (const key of result.downloaded) {
        console.log(`downloaded ${key}`);
      }
      console.log(
        `sync complete: ${result.uploaded.length} uploaded, ${result.downloaded.length} downloaded, ${result.unchanged.length} unchanged`
      );
    } catch (err) {
      console.error(`syncbox: sync failed: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  if (command === 'status') {
    try {
      const result = await status.run(config);
      if (result.toUpload.length === 0 && result.toDownload.length === 0) {
        console.log('status: local and server are in sync, nothing to do');
      } else {
        for (const key of result.toUpload) {
          console.log(`would upload (local -> server): ${key}`);
        }
        for (const key of result.toDownload) {
          console.log(`would download (server -> local): ${key}`);
        }
        console.log(
          `status complete: ${result.toUpload.length} would be uploaded, ${result.toDownload.length} would be downloaded`
        );
      }
    } catch (err) {
      console.error(`syncbox: status failed: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  console.error(`syncbox: '${command}' is not implemented yet`);
  process.exitCode = 1;
}

main();
