# inet

`inet.sh` is a small cross-platform helper to disable and re-enable internet access for Wi-Fi and Ethernet adapters from the command line.


![License](https://img.shields.io/github/license/rokath/inet) ![GitHub issues](https://img.shields.io/github/issues/rokath/inet) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://makeapullrequest.com) 

## Usage

```bash
./inet.sh
./inet.sh off
./inet.sh on
```

- `./inet.sh` shows a short status/help message.
- `./inet.sh off` disables matching network adapters.
- `./inet.sh on` re-enables matching network adapters.

## Install

Simply download script and run it.

## Notes

- The script is intended for Windows, Linux, and macOS.
- Administrative privileges are required to change adapter state.
- The script is not fully tested yet.

## Test Status

- [x] Windows Git Bash: Ethernet
- [ ] Windows Git Bash: Wi-Fi
- [ ] Linux: Ethernet
- [ ] Linux: Wi-Fi
- [ ] macOS: Ethernet
- [x] macOS: Wi-Fi
