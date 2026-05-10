"""
Kafka Topic Creator for Weather Prediction Pipeline
----------------------------------------------------
Creates 3 topics:
  1. weather-raw-data    -- Raw weather sensor readings
  2. weather-predictions -- 7-day weather forecasts
  3. weather-alerts      -- Severe weather alerts

Usage:
    python create_topics.py
"""

from kafka.admin import KafkaAdminClient, NewTopic
from kafka.errors import TopicAlreadyExistsError

BOOTSTRAP_SERVERS = "localhost:9092,localhost:9094"

TOPICS = [
    {
        "name": "weather-raw-data",
        "partitions": 3,
        "replication_factor": 2,
        "description": "Raw weather readings from cities",
    },
    {
        "name": "weather-predictions",
        "partitions": 3,
        "replication_factor": 2,
        "description": "7-day weather forecast predictions",
    },
    {
        "name": "weather-alerts",
        "partitions": 2,
        "replication_factor": 2,
        "description": "Severe weather alerts (storms, extreme temps, etc.)",
    },
]


def create_topics():
    print(f"Connecting to Kafka at {BOOTSTRAP_SERVERS}...")
    admin = KafkaAdminClient(
        bootstrap_servers=BOOTSTRAP_SERVERS,
        client_id="weather-topic-creator",
    )

    new_topics = []
    for topic in TOPICS:
        new_topics.append(
            NewTopic(
                name=topic["name"],
                num_partitions=topic["partitions"],
                replication_factor=topic["replication_factor"],
            )
        )

    for topic_obj, topic_info in zip(new_topics, TOPICS):
        try:
            admin.create_topics(new_topics=[topic_obj], validate_only=False)
            print(
                f"  [CREATED]  {topic_info['name']:<25} "
                f"partitions={topic_info['partitions']}  "
                f"replication={topic_info['replication_factor']}  "
                f"-- {topic_info['description']}"
            )
        except TopicAlreadyExistsError:
            print(
                f"  [EXISTS]   {topic_info['name']:<25} "
                f"-- already exists, skipping"
            )

    existing = admin.list_topics()
    print(f"\nAll topics in cluster: {existing}")
    admin.close()
    print("\nDone.")


if __name__ == "__main__":
    create_topics()
