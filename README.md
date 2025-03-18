# Website Resource Usage Monitoring Script for EnhanceCP

## Overview
This Bash script retrieves real-time CPU, Memory, and I/O usage for a specific website running in a cgroup-based hosting environment. It provides live statistics, including:
- **CPU Usage (%)**
- **Memory Usage (MB and Percentage)**
- **I/O Read, Write, and Total Speed (MB/s)**

## Prerequisites
- The system must support **cgroups v2**.
- The cgroup path should be **`/sys/fs/cgroup/websites/<website_id>`**.
- The script must be executed with appropriate permissions to read cgroup files.

## Installation
1. Copy the script to a directory on your server.
2. Give it execution permissions:
   ```bash
   chmod +x usage.sh
   ```

## Usage
Run the script by providing a **Website ID** as an argument:
```bash
./usage.sh <website_id>
```

### Example:
```bash
./usage.sh 98f79a38-2fc4-462b-8c99-ea111d0e3cea
```
#### Sample Output:
```
Website ID: 98f79a38-2fc4-462b-8c99-ea111d0e3cea
CPU Usage: 75.34%
Memory Usage: 2750 MB / 3072 MB (89.55%)
IO Usage: Read 1.85 MB/s, Write 0.92 MB/s, Total 2.77 MB/s
```

## Explanation of Metrics
- **CPU Usage (%)**: Measures the CPU time consumed relative to the allocated limit.
- **Memory Usage (MB)**: Displays the current memory consumption and total available memory for the website.
- **IO Usage (MB/s)**:
  - **Read MB/s**: Disk read speed in megabytes per second.
  - **Write MB/s**: Disk write speed in megabytes per second.
  - **Total MB/s**: Combined read and write speed.

## Notes
- If a **website ID does not exist**, the script will return an error.
- If **memory.max** is set to `max`, it uses the total system memory.
- The script **waits for 1 second** to measure I/O speed accurately.

## License
This script is open-source and free to use under the MIT License.

