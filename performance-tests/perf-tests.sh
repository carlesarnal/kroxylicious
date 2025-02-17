#!/usr/bin/env bash
#
# Copyright Kroxylicious Authors.
#
# Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
#

set -eo pipefail
PERF_TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

TEST=${TEST:-'[0-9][0-9]-.*'}
RECORD_SIZE=${RECORD_SIZE:-1024}
NUM_RECORDS=${NUM_RECORDS:-10000000}
WARM_UP_NUM_RECORDS_POST_BROKER_START=${WARM_UP_NUM_RECORDS_POST_BROKER_START:-1000}
WARM_UP_NUM_RECORDS_PRE_TEST=${WARM_UP_NUM_RECORDS_PRE_TEST:-1000}

ON_SHUTDOWN=()
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NOCOLOR='\033[0m'

KROXYLICIOUS_CHECKOUT=${KROXYLICIOUS_CHECKOUT:-${PERF_TESTS_DIR}/..}

KAFKA_VERSION=${KAFKA_VERSION:-$(mvn -f ${KROXYLICIOUS_CHECKOUT}/pom.xml org.apache.maven.plugins:maven-help-plugin:3.4.0:evaluate -Dexpression=kafka.version -q -DforceStdout)}
STRIMZI_VERSION=${STRIMZI_VERSION:-$(mvn -f ${KROXYLICIOUS_CHECKOUT}/pom.xml org.apache.maven.plugins:maven-help-plugin:3.4.0:evaluate -Dexpression=strimzi.version -q -DforceStdout)}
KAFKA_TOOL_IMAGE=${KAFKA_TOOL_IMAGE:-quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}}
PERF_NETWORK=performance-tests_perf_network
export KAFKA_VERSION KAFKA_TOOL_IMAGE

runDockerCompose () {
  docker-compose -f ${PERF_TESTS_DIR}/docker-compose.yaml "${@}"
}

doCreateTopic () {
  local TOPIC
  ENDPOINT=$1
  TOPIC=$2
  docker run --rm --network ${PERF_NETWORK} ${KAFKA_TOOL_IMAGE}  \
      bin/kafka-topics.sh --create --topic ${TOPIC} --bootstrap-server ${ENDPOINT} 1>/dev/null
}

doDeleteTopic () {
  local ENDPOINT
  local TOPIC
  ENDPOINT=$1
  TOPIC=$2
  docker run --rm --network  ${PERF_NETWORK} ${KAFKA_TOOL_IMAGE}  \
      bin/kafka-topics.sh --delete --topic ${TOPIC} --bootstrap-server ${ENDPOINT}
}

warmUp() {
  echo -e "${YELLOW}Running warm up${NOCOLOR}"
  producerPerf $1 $2 ${WARM_UP_NUM_RECORDS_PRE_TEST} /dev/null > /dev/null
  consumerPerf $1 $2 ${WARM_UP_NUM_RECORDS_PRE_TEST} /dev/null > /dev/null
}

# runs kafka-producer-perf-test.sh transforming the output to an array of objects
producerPerf() {
  local ENDPOINT
  local TOPIC
  local NUM_RECORDS
  local OUTPUT
  ENDPOINT=$1
  TOPIC=$2
  NUM_RECORDS=$3
  OUTPUT=$4

  echo -e "${YELLOW}Running producer test${NOCOLOR}"

  # Input:
  # 250000 records sent, 41757.140471 records/sec (40.78 MB/sec), 639.48 ms avg latency, 782.00 ms max latency
  # 250000 records sent, 41757.140471 records/sec (40.78 MB/sec), 639.48 ms avg latency, 782.00 ms max latency, 670 ms 50th, 771 ms 95th, 777 ms 99th, 781 ms 99.9th
  # Output:
  # [
  #  { "sent": 204796, "rate_rps": 40959.2, "rate_mips": 40.00, "avg_lat_ms": 627.9, "max_lat_ms": 759.0 },
  #  { "sent": 300000, "rate_rps": 43184.108248, "rate_mips": 42.17, "avg_lat_ms": 627.62, "max_lat_ms": 759.00,
  #    "percentile50": 644, "percentile95": 744, "percentile99": 753, "percentile999": 758 }
  # ]

  docker run --rm --network ${PERF_NETWORK} ${KAFKA_TOOL_IMAGE}  \
      bin/kafka-producer-perf-test.sh --topic ${TOPIC} --throughput -1 --num-records ${NUM_RECORDS} --record-size ${RECORD_SIZE} \
      --producer-props acks=all bootstrap.servers=${ENDPOINT} | \
      jq --raw-input --arg name "${TESTNAME}" '[.,inputs] | [.[] | match("^(?<sent>\\d+) *records sent" +
                                    ", *(?<rate_rps>\\d+[.]?\\d*) records/sec [(](?<rate_mips>\\d+[.]?\\d*) MB/sec[)]" +
                                    ", *(?<avg_lat_ms>\\d+[.]?\\d*) ms avg latency" +
                                    ", *(?<max_lat_ms>\\d+[.]?\\d*) ms max latency" +
                                    "(?<inflight>" +
                                    ", *(?<percentile50>\\d+[.]?\\d*) ms 50th" +
                                    ", *(?<percentile95>\\d+[.]?\\d*) ms 95th" +
                                    ", *(?<percentile99>\\d+[.]?\\d*) ms 99th" +
                                    ", *(?<percentile999>\\d+[.]?\\d*) ms 99.9th" +
                                    ")?" +
                                    "[.]"; "g")]  |
                                 {name: $name, values: [.[] | .captures | map( { (.name|tostring): ( .string | tonumber? ) } ) | add | del(..|nulls)]}' > ${OUTPUT}
}

consumerPerf() {
  local ENDPOINT
  local TOPIC
  local NUM_RECORDS
  local OUTPUT

  ENDPOINT=$1
  TOPIC=$2
  NUM_RECORDS=$3
  OUTPUT=$4

  echo -e "${YELLOW}Running consumer test${NOCOLOR}"

  # Input:
  # start.time, end.time, data.consumed.in.MB, MB.sec, data.consumed.in.nMsg, nMsg.sec, rebalance.time.ms, fetch.time.ms, fetch.MB.sec, fetch.nMsg.sec
  # 2024-02-21 19:36:23:839, 2024-02-21 19:36:24:256, 0.9766, 2.3419, 1000, 2398.0815, 364, 53, 18.4257, 18867.9245  # Output:
  # Output
  # [
  #  { "sent": 204796, "rate_rps": 40959.2, "rate_mips": 40.00, "avg_lat_ms": 627.9, "max_lat_ms": 759.0 },
  #  { "sent": 300000, "rate_rps": 43184.108248, "rate_mips": 42.17, "avg_lat_ms": 627.62, "max_lat_ms": 759.00,
  #    "percentile50": 644, "percentile95": 744, "percentile99": 753, "percentile999": 758 }
  # ]

  docker run --rm --network ${PERF_NETWORK} ${KAFKA_TOOL_IMAGE}  \
      bin/kafka-consumer-perf-test.sh --topic ${TOPIC} --messages ${NUM_RECORDS} --hide-header \
      --bootstrap-server ${ENDPOINT} |
       jq --raw-input --arg name "${TESTNAME}" '[.,inputs] | [.[] | match("^(?<start.time>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}:\\d{3}), " +
                                        "(?<end.time>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}:\\d{3}), " +
                                        "(?<data.consumed.in.MB>\\d+[.]?\\d*), " +
                                        "(?<MB.sec>\\d+[.]?\\d*), " +
                                        "(?<data.consumed.in.nMsg>\\d+[.]?\\d*), " +
                                        "(?<nMsg.sec>\\d+[.]?\\d*), " +
                                        "(?<rebalance.time.ms>\\d+[.]?\\d*), " +
                                        "(?<fetch.time.ms>\\d+[.]?\\d*), " +
                                        "(?<fetch.MB.sec>\\d+[.]?\\d*), " +
                                        "(?<fetch.nMsg.sec>\\d+[.]?\\d*)"; "g")] |
                                 { name: $name, values: [.[] | .captures | map( { (.name|tostring): ( .string | tonumber? ) } ) | add | del(..|nulls)]}' > ${OUTPUT}
}

# expects TEST_NAME, TOPIC, ENDPOINT, PRODUCER_RESULT and CONSUMER_RESULT to be set
doPerfTest () {
  doCreateTopic ${ENDPOINT} ${TOPIC}
  warmUp ${ENDPOINT} ${TOPIC}

  producerPerf ${ENDPOINT} ${TOPIC} ${NUM_RECORDS} ${PRODUCER_RESULT}
  consumerPerf ${ENDPOINT} ${TOPIC} ${NUM_RECORDS} ${CONSUMER_RESULT}

  doDeleteTopic ${ENDPOINT} ${TOPIC}
}

onExit() {
  for cmd in "${ON_SHUTDOWN[@]}"
  do
    eval ${cmd}
  done
}

trap onExit EXIT

TMP=$(mktemp -d)
ON_SHUTDOWN+=("rm -rf ${TMP}")

# Bring up Kafka
ON_SHUTDOWN+=("runDockerCompose down")
runDockerCompose pull
runDockerCompose up --detach --wait kafka

# Warm up the broker - we do this separately as we might want a longer warm-up period
doCreateTopic broker1:9092 warmup-topic
warmUp broker1:9092 warmup-topic ${WARM_UP_NUM_RECORDS_POST_BROKER_START}
doDeleteTopic broker1:9092 warmup-topic

echo -e "${GREEN}Running test cases, number of records = ${NUM_RECORDS}, record size ${RECORD_SIZE}${NOCOLOR}"

PRODUCER_RESULTS=()
CONSUMER_RESULTS=()
for t in $(find ${PERF_TESTS_DIR} -type d -regex '.*/'${TEST} | sort)
do
  TESTNAME=$(basename $t)
  TEST_TMP=${TMP}/${TESTNAME}
  mkdir -p ${TEST_TMP}
  PRODUCER_RESULT=${TEST_TMP}/producer.json
  CONSUMER_RESULT=${TEST_TMP}/consumer.json
  TOPIC=perf-test-${RANDOM}

  echo -e "${GREEN}Running ${TESTNAME} ${NOCOLOR}"

  TESTNAME=${TESTNAME} TOPIC=${TOPIC} PRODUCER_RESULT=${PRODUCER_RESULT} CONSUMER_RESULT=${CONSUMER_RESULT} . ${t}/run.sh

  PRODUCER_RESULTS+=(${PRODUCER_RESULT})
  CONSUMER_RESULTS+=(${CONSUMER_RESULT})
done

# Summarise results

echo -e "${GREEN}Producer Results ${NOCOLOR}"

jq -r -s '(["Name","Sent","Rate rec/s", "Rate Mi/s", "Avg Lat ms", "Max Lat ms", "Percentile50", "Percentile95", "Percentile99", "Percentile999"] | (., map(length*"-"))),
           (.[] | [ .name, (.values | last | .[]) ]) | @tsv' "${PRODUCER_RESULTS[@]}" | column -t -s $'\t'

echo -e "${GREEN}Consumer Results ${NOCOLOR}"

jq -r -s '(["Name","Consumed Mi","Consumed Mi/s", "Consumed recs", "Consumed rec/s", "Rebalance Time ms", "Fetch Time ms", "Fetch Mi/s", "Fetch rec/s"] | (., map(length*"-"))),
           (.[] | [ .name, (.values  | last | .[]) ]) | @tsv' "${CONSUMER_RESULTS[@]}" | column -t -s $'\t'


# Write output for integration with Kibana in the CI pipeline
# This maintains the existing interface
if [[ -n "${KIBANA_OUTPUT_DIR}" && -d "${KIBANA_OUTPUT_DIR}" ]]; then
  for PRODUCER_RESULT in "${PRODUCER_RESULTS[@]}"
  do
    DIR=${KIBANA_OUTPUT_DIR}/$(jq -r '.name' ${PRODUCER_RESULT})
    mkdir -p ${DIR}
    jq '.values | last | [{name: "AVG Latency", unit: "ms", value: .avg_lat_ms},
                          {name: "95th Latency", unit: "ms", value: .percentile95},
                          {name: "99th Latency", unit: "ms", value: .percentile99}]' ${PRODUCER_RESULT} > ${DIR}/producer.json
  done

  for CONSUMER_RESULT in "${CONSUMER_RESULTS[@]}"
  do
    DIR=${KIBANA_OUTPUT_DIR}/$(jq -r '.name' ${CONSUMER_RESULT})
    jq '[.values | last | to_entries[] | { name: .key, value} ]' ${CONSUMER_RESULT} > ${DIR}/consumer.json
  done
fi
