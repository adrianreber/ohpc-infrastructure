#!/bin/bash

set -o pipefail

if [ ! -e /etc/sysconfig/openhpc-test.config ]; then
	echo "Input file /etc/sysconfig/openhpc-test.config missing"
	exit 1
fi

. /etc/sysconfig/openhpc-test.config

if [[ "${SMS}" == "openhpc-lenovo-jenkins-sms" ]]; then
	LAUNCHER="lenovo_launch_sms.sh"
elif [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
	LAUNCHER="huawei_launch_sms.sh"
else
	echo "Unknown system. Exiting"
	exit 1
fi

cd ../../../../

LOG=$(mktemp)
OUT=$(mktemp -d)
RESULT=FAIL
RESULTS="/results"
VERSION="${2}"
DISTRIBUTION="${1}"
REPO="${3}"
VERSION_MAJOR=$(echo "${VERSION}" | awk -F. '{print $1}')
if [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
	TEST_ARCH="aarch64"
	CI_CLUSTER=huawei
	COMPUTE_HOSTS="openhpc-oe-jenkins-c1, openhpc-oe-jenkins-c2"
else
	TEST_ARCH=$(uname -m)
	CI_CLUSTER=lenovo
	COMPUTE_HOSTS="openhpc-lenovo-jenkins-c1, openhpc-lenovo-jenkins-c2"
fi

if [ ! -d "${RESULTS}" ]; then
	echo "Results directory (${RESULTS}) missing. Exiting"
	exit 1
fi

cleanup() {
	if [ ! -d "${RESULTS}/${VERSION_MAJOR}" ]; then
		mkdir "${RESULTS}/${VERSION_MAJOR}"
	fi
	if [ ! -d "${RESULTS}/${VERSION_MAJOR}/${VERSION}" ]; then
		mkdir "${RESULTS}/${VERSION_MAJOR}/${VERSION}"
	fi
	if [ -s "${OUT}"/test-results.tar ]; then
		cd "${OUT}"
		set +e
		tar xf test-results.tar
		/usr/local/junit2html/bin/junit2html --merge results tests
		/usr/local/junit2html/bin/junit2html results --summary-matrix | tee -a "${LOG}"
		/usr/local/junit2html/bin/junit2html results --report-matrix junit.html
		rm -rf tests
		cd - >/dev/null
		set -e
	fi
	echo "Finished at $(date -u +"%Y-%m-%d-%H-%M-%S")" >>"${LOG}"
	mv "${LOG}" "${OUT}"/console.out
	chmod 644 "${OUT}"/console.out
	sed -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" -i "${OUT}"/console.out
	touch "${OUT}/${RESULT}"
	DEST_DIR="${RESULTS}/${VERSION_MAJOR}/${VERSION}"
	DEST_NAME="$(date -u +"%Y-%m-%d-%H-%M-%S")-${RESULT}-OHPC-${VERSION}-${DISTRIBUTION}-${TEST_ARCH}-${RANDOM}"
	mv "${OUT}" "${DEST_DIR}/${DEST_NAME}"
	chmod 755 "${DEST_DIR}/${DEST_NAME}"
	cd "${DEST_DIR}"
	ln -sfn "${DEST_NAME}" "0-LATEST-OHPC-${VERSION}-${DISTRIBUTION}-${TEST_ARCH}"
	cd - >/dev/null
	rsync -a /results ohpc@repos.ohpc.io:/stats/
	ssh ohpc@repos.ohpc.io /home/ohpc/bin/update_results.sh "${VERSION_MAJOR}" "${VERSION}"
	# save CPAN cache
	if [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
		ssh "${BOOT_SERVER}" "bash -c \"rsync -az --info=progress2 --zl 9 --exclude=CPAN/MyConfig.pm ${SMS}:/root/.cpan/ /root/.cache/cpan-backup/\""
	fi
	if [ "${RESULT}" == "PASS" ]; then
		exit 0
	else
		exit 1
	fi
}

echo "Started at $(date -u +"%Y-%m-%d-%H-%M-%S")" >"${LOG}"

if ! "ansible/roles/test/files/${LAUNCHER}" "${SMS}" ${DISTRIBUTION} ${VERSION} "${ROOT_PASSWORD}" | tee -a "${LOG}"; then
	cd - >/dev/null
	echo "Provisiong ${SMS} failed. Exiting" | tee -a "${LOG}"
	cleanup
fi

cd - >/dev/null

set -e

VARS=$(mktemp)

cat vars >"${VARS}"
echo "export IPMI_PASSWORD=${SMS_IPMI_PASSWORD}" >>"${VARS}"

set -x

echo "export BaseOS=${DISTRIBUTION}" >>"${VARS}"
echo "export Version=${VERSION}" >>"${VARS}"
echo "export Architecture=${TEST_ARCH}" >>"${VARS}"
echo "export SMS=${SMS}" >>"${VARS}"
echo "export NODE_NAME=${SMS}" >>"${VARS}"
echo "export Repo=${REPO}" >>"${VARS}"
echo "export CI_CLUSTER=${CI_CLUSTER}" >>"${VARS}"
echo "export COMPUTE_HOSTS=\"${COMPUTE_HOSTS}\"" >>"${VARS}"

if [[ "${DISTRIBUTION}" == "almalinux"* ]] && [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://mirrors.nju.edu.cn/almalinux/" >>"${VARS}"
fi
if [[ "${DISTRIBUTION}" == "openEuler"* ]] && [[ "${SMS}" == "openhpc-lenovo-jenkins-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://repo.huaweicloud.com/openeuler/" >>"${VARS}"
fi

scp "${VARS}" "${SMS}":/root/vars

set +x

echo "Running install.sh on ${SMS}"
if timeout --signal=9 100m ssh "${SMS}" 'bash -c "source /root/vars; /root/ci/install.sh"' 2>&1 | sed -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" | tee -a "${LOG}"; then
	RESULT=PASS
else
	echo "Running tests on ${SMS} failed!" | tee -a "${LOG}"
fi

rm -f "${VARS}"

ssh "${SMS}" "mkdir -p /home/ohpc-test/tests; cp *log.xml /home/ohpc-test/tests; cd /home/ohpc-test; find . -name '*log.xml' -print0 | tar -cf - --null -T -" >"${OUT}"/test-results.tar
cleanup

exit 1
