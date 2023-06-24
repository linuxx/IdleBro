# IdleBro

IdleBro is a C++ program designed to prevent Oracle's Free Tier compute instances from being shut down due to idle resource usage. Oracle's Free Tier has certain conditions that deem an instance as idle, leading to possible reclamation by Oracle. IdleBro helps keep your compute instance active by consuming CPU and memory resources, ensuring it meets the utilization criteria.

## Overview

Oracle's Free Tier compute instances may be reclaimed if they are deemed idle for a period of 7 days based on specific utilization thresholds. IdleBro addresses this issue by continuously consuming CPU and memory resources, keeping the utilization levels above the threshold, and preventing the instance from being shut down.

IdleBro runs as a daemon on Linux and allows you to configure the CPU and memory consumption levels within specified upper and lower limits. It provides flexibility by introducing randomness to the resource consumption, allowing dynamic fluctuations within the configured range.

## Features

- Runs as a daemon on Linux, ensuring continuous resource consumption.
- Configurable CPU and memory consumption levels.
- Randomness factor introduces dynamic fluctuations in resource consumption.
- Prevents Oracle's Free Tier compute instances from being shut down due to idle resource usage.

## Installation

1. Clone the IdleBro repository:

   ```shell
   git clone https://github.com/your-username/IdleBro.git
   

2. Change into the IdleBro directory:

	```shell
	cd IdleBro











"Play stupid games, win stupid prizes"
								-Somebody