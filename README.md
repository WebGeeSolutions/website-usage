# Website Usage Monitor

A simple bash script to monitor website resource usage in a cgroup-based environment.

## Features

- Monitor CPU usage
- Monitor Memory usage
- Monitor IO operations
- Monitor process count
- Interactive website selection mode
- Real-time monitoring with watch mode
- JSON output format for integration
- Color-coded output for better readability

## Requirements

- Bash shell
- cgroup v2 support
- bc (for calculations)
- awk
- stat

## Installation

### Quick Installation

Setting up website-usage is quick and easy. Run the following command to install it on your server:

```bash
bash <(curl -fsSL https://tools.webgee.com/enhance/usage/installer.sh)
```

If curl is unavailable, you can use:

```bash
bash <(wget -qO- https://tools.webgee.com/enhance/usage/installer.sh)
```

This command downloads and installs the script to `/usr/bin/website-usage`, making it accessible system-wide.

### Manual Installation

1. Clone this repository:
```bash
git clone https://github.com/yourusername/website-usage.git
cd website-usage
```

2. Make the script executable:
```bash
chmod +x usagev2.sh
```

## Usage

The script can be used in several ways:

1. Interactive Mode (Select from available websites):
```bash
./usagev2.sh
```

2. Direct Mode (Specify website ID):
```bash
./usagev2.sh <website_id>
```

3. Watch Mode (Continuous monitoring):
```bash
./usagev2.sh --watch <website_id>
```

4. JSON Output Mode:
```bash
./usagev2.sh --json <website_id>
```

## Options

- `--help`: Display help message
- `--watch`: Enable continuous monitoring mode
- `--json`: Output in JSON format

## Output Example

```
Website Information:
ID: abc123
Owner: webuser
CPU Usage: 45.23% (4 cores)
Memory Usage: 256 MB / 1024 MB (25.00%)
IO Usage:
  Read:  1.23 MB/s
  Write: 0.45 MB/s
  Total: 1.68 MB/s
Processes: 12 / 50
----------------------------------------
```

## JSON Output Example

```json
{
  "website_id": "abc123",
  "owner": "webuser",
  "cpu": {
    "usage": 45.23,
    "cores": 4,
    "quota": 100000,
    "period": 100000
  },
  "memory": {
    "used": 256,
    "max": 1024,
    "percentage": 25.00
  },
  "io": {
    "read": 1.23,
    "write": 0.45,
    "total": 1.68
  },
  "processes": {
    "current": 12,
    "max": 50
  }
}
```

## Contributors

### WebGee
- Website: [https://webgee.com](https://webgee.com)
- Contact: support@webgee.com
- Contributions:
  - Interactive website selection mode
  - JSON output format
  - Watch mode
  - Additional metrics and improved formatting

### 8DCloud
- Website: [https://8dcloud.com](https://8dcloud.com)
- Contributions:
  - Color-coded output
  - Enhanced the original `usage.sh` script
  - Created the new `siteinfo.sh` script
  - Added better error handling and user feedback

## License

This project is licensed under the MIT License - see the LICENSE file for details.

