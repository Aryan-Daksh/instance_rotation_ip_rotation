AWS EC2 Spot + Failover Pool Management (Bash-based)
Goal
I wanted a Bash system to manage a pool of AWS EC2 instances for ephemeral tasks:
	1. Prefer Spot instances for cost efficiency.
	2. Use fallback On-Demand instances when Spot instances fail.
	3. Dynamically maintain a pool of ready-to-use instances.
	4. Minimize delays when getting an instance IP (get_instance.sh start should return quickly).
	5. Cleanly stop/terminate instances after use.

Key Scripts
1. get_instance.sh
Handles starting/stopping instances and asynchronously refilling the pool.
	• Pool File: /tmp/spot_pool.json
		○ Format: [{ "id": INSTANCE_ID, "ip": IP|null, "type": "spot|fallback" }, ...]
	• Start Logic:
		○ Loops the pool until it finds an entry with a usable IP.
		○ Returns the IP immediately.
		○ Saves current instance ID and type in /tmp/current_instance_id and /tmp/current_instance_type.
		○ Removes used instance from the pool.
		○ Asynchronous Refill:
			§ Launches a new Spot instance in the background.
			§ Adds it to the pool immediately with "ip": null.
			§ Waits for the instance to start and updates IP in the pool asynchronously.
			§ If Spot launch fails, fallback On-Demand instances are started and added to the pool with "ip": null.
	• Stop Logic:
		○ Terminates Spot instances or stops On-Demand instances.
		○ Removes stale entries from the pool.
		○ Cleans up temporary files.
	• Notes:
		○ Never hands out an unready instance (IP null).
		○ Failover instances only run if Spot refill fails, and can be replaced later by Spot instances.
		○ No synchronous blocking occurs during background pool refills.

2. init_pool.sh
Initializes the pool with pre-launched Spot instances.
	• Parameters: Pool size, availability zones.
	• Behavior:
		○ Loops to launch the required number of Spot instances.
		○ Waits for instances to start and fetches their public IPs synchronously.
		○ Adds each instance to the pool JSON with "type": "spot".
		○ Logs progress and handles multiple availability zones if a launch fails in one AZ.
	• Goal: Have a ready-to-use pool of Spot instances at startup.

3. terminate_all.sh
Cleans up the entire pool.
	• Behavior:
		○ Reads all instance IDs from /tmp/spot_pool.json.
		○ Terminates Spot instances.
		○ Stops fallback On-Demand instances (if running).
		○ Cleans up temporary files, including /tmp/current_instance_id and /tmp/current_instance_type.
	• Goal: Reset pool and stop all running instances safely.

Overall Flow
	1. Pool Initialization (init_pool.sh):
		○ Pre-launch Spot instances.
		○ Wait for them to start.
		○ Populate /tmp/spot_pool.json with IDs and IPs.
	2. Getting an Instance (get_instance.sh start):
		○ Pick the first ready instance from the pool.
		○ Return its IP immediately.
		○ Remove it from the pool.
		○ Start asynchronous refill:
			§ Try Spot first → add to pool with "ip": null.
			§ Wait and update IP in pool asynchronously.
			§ If Spot fails → launch fallback instances.
	3. Stopping an Instance (get_instance.sh stop):
		○ Terminates Spot instances or stops fallback instances.
		○ Removes stale entries from the pool.
	4. Pool Cleanup (terminate_all.sh):
		○ Stops all running instances (Spot and fallback).
		○ Clears pool JSON and temporary files.

Behavior Notes
	• Failover instances are only launched when Spot fails, and are tracked in the pool similarly to Spot instances.
	• Pool entries with "ip": null remain until they are updated asynchronously.
	• get_instance start never waits for new IP allocation; it only uses ready instances.
	• Multiple fallback instances are supported and can be replaced by Spot instances once they become available.
	• Asynchronous operations prevent blocking the main flow while maintaining a fully functional dynamic pool.





Usage

init_pool.sh #This initializes the pool for 5 spot instances

IP=$(./get_instancev2.sh start)
curl -X POST http://$IP:8080 -d '{}
./get_instancev2.sh stop


Terminate_all.sh #This terminates the pool of Instances and stops a failover instance.






