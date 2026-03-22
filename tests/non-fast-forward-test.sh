#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 OpenAI
# SPDX-License-Identifier: GPL-2.0-or-later
set -efuC -o pipefail
shopt -s inherit_errexit

assert() {
    "$@" || {
        echo "Assertion failed: $*" >&2
        return 1
    }
}

assert_eq() {
    local -r expected="${1}"
    local -r actual="${2}"
    local -r message="${3:-expected values to match}"

    [[ "${expected}" = "${actual}" ]] || {
        echo "Assertion failed: ${message}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    }
}

expect_failure() {
    if "$@"; then
        echo "Expected command to fail: $*" >&2
        return 1
    fi
}

section() {
    echo
    echo "== $* =="
}

make_commit() {
    local -r repo="${1}"
    local -r filename="${2}"
    local -r line="${3}"
    local -r message="${4}"

    printf '%s\n' "${line}" >> "${repo}/${filename}"
    git -C "${repo}" add -- "${filename}"
    git -C "${repo}" commit -m "${message}" >/dev/null
}

remote_ref_oid() {
    git ls-remote "${1}" "${2}" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

umask 077
tempdir=$(mktemp -d)
readonly tempdir
trap "rm -Rf -- '${tempdir}'" EXIT

PATH="$(git rev-parse --show-toplevel):${PATH}"
readonly PATH
export PATH

git_env=$(env | sed -n 's/^\(GIT_[^=]*\)=.*$/\1/p')
IFS=$'\n' unset ${git_env}

export GNUPGHOME="${tempdir}/gpg"
mkdir "${GNUPGHOME}"
cat << 'EOF' > "${GNUPGHOME}/gpg"
#!/usr/bin/env bash
set -efuC -o pipefail; shopt -s inherit_errexit
args=( "${@}" )
for ((i = 0; i < ${#}; ++i)); do
    if [[ ${args[${i}]} = "--secret-keyring" ]]; then
        unset "args[${i}]" "args[$(( i + 1 ))]"
        break
    fi
done
exec gpg "${args[@]}"
EOF
chmod +x "${GNUPGHOME}/gpg"

export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="${tempdir}/gitconfig"
mkdir "${tempdir}/template"
git config --global init.defaultBranch main
git config --global user.name git-remote-gcrypt
git config --global user.email git-remote-gcrypt@example.com
git config --global init.templateDir "${tempdir}/template"
git config --global gpg.program "${GNUPGHOME}/gpg"

section "Creating a test GPG key"
gpg --batch --passphrase "" --quick-generate-key \
    "git-remote-gcrypt <git-remote-gcrypt@example.com>" >/dev/null 2>&1

section "Plain Git rejects a divergent push"
plain_remote="${tempdir}/plain.git"
plain_a="${tempdir}/plain-a"
plain_b="${tempdir}/plain-b"
git init --bare -- "${plain_remote}" >/dev/null
git init -- "${plain_a}" >/dev/null
git -C "${plain_a}" remote add origin "${plain_remote}"
make_commit "${plain_a}" file.txt "base" "base"
git -C "${plain_a}" push -u origin main >/dev/null
git clone -b main "${plain_remote}" "${plain_b}" >/dev/null
make_commit "${plain_a}" file.txt "a1" "a1"
git -C "${plain_a}" push origin main >/dev/null
plain_a_tip=$(git -C "${plain_a}" rev-parse HEAD)
make_commit "${plain_b}" file.txt "b1" "b1"
plain_b_push_log="${tempdir}/plain-b-push.log"
expect_failure git -C "${plain_b}" push origin main >"${plain_b_push_log}" 2>&1
assert grep -E "non-fast-forward|fetch first|rejected" "${plain_b_push_log}" >/dev/null
assert_eq "${plain_a_tip}" \
    "$(git -C "${plain_remote}" rev-parse refs/heads/main)" \
    "plain git remote should stay on A after rejecting B"

section "gcrypt rejects a divergent push"
gcrypt_reject_remote_git="${tempdir}/gcrypt-reject.git"
gcrypt_reject_remote="gcrypt::${gcrypt_reject_remote_git}#main"
gcrypt_reject_a="${tempdir}/gcrypt-reject-a"
gcrypt_reject_b="${tempdir}/gcrypt-reject-b"
git init --bare -- "${gcrypt_reject_remote_git}" >/dev/null
git init -- "${gcrypt_reject_a}" >/dev/null
git -C "${gcrypt_reject_a}" remote add origin "${gcrypt_reject_remote}"
make_commit "${gcrypt_reject_a}" file.txt "base" "base"
git -C "${gcrypt_reject_a}" push -f origin main >/dev/null
git clone -b main "${gcrypt_reject_remote}" "${gcrypt_reject_b}" >/dev/null
make_commit "${gcrypt_reject_a}" file.txt "a1" "a1"
git -C "${gcrypt_reject_a}" push origin main >/dev/null
gcrypt_reject_a_tip=$(git -C "${gcrypt_reject_a}" rev-parse HEAD)
make_commit "${gcrypt_reject_b}" file.txt "b1" "b1"
gcrypt_reject_b_push_log="${tempdir}/gcrypt-reject-b-push.log"
expect_failure git -C "${gcrypt_reject_b}" push origin main >"${gcrypt_reject_b_push_log}" 2>&1
assert grep -E "non-fast-forward|rejected" "${gcrypt_reject_b_push_log}" >/dev/null
assert_eq "${gcrypt_reject_a_tip}" \
    "$(remote_ref_oid "${gcrypt_reject_remote}" refs/heads/main)" \
    "gcrypt remote should stay on A after rejecting B"

section "gcrypt accepts a forced divergent push"
gcrypt_force_remote_git="${tempdir}/gcrypt-force.git"
gcrypt_force_remote="gcrypt::${gcrypt_force_remote_git}#main"
gcrypt_force_a="${tempdir}/gcrypt-force-a"
gcrypt_force_b="${tempdir}/gcrypt-force-b"
git init --bare -- "${gcrypt_force_remote_git}" >/dev/null
git init -- "${gcrypt_force_a}" >/dev/null
git -C "${gcrypt_force_a}" remote add origin "${gcrypt_force_remote}"
make_commit "${gcrypt_force_a}" file.txt "base" "base"
git -C "${gcrypt_force_a}" push -f origin main >/dev/null
git clone -b main "${gcrypt_force_remote}" "${gcrypt_force_b}" >/dev/null
make_commit "${gcrypt_force_a}" file.txt "a1" "a1"
git -C "${gcrypt_force_a}" push origin main >/dev/null
make_commit "${gcrypt_force_b}" file.txt "b1" "b1"
git -C "${gcrypt_force_b}" push origin +main:main >/dev/null
assert_eq "$(git -C "${gcrypt_force_b}" rev-parse HEAD)" \
    "$(remote_ref_oid "${gcrypt_force_remote}" refs/heads/main)" \
    "forced gcrypt push should move remote to B"

section "gcrypt accepts a sequential second push"
gcrypt_seq_remote_git="${tempdir}/gcrypt-seq.git"
gcrypt_seq_remote="gcrypt::${gcrypt_seq_remote_git}#main"
gcrypt_seq_repo="${tempdir}/gcrypt-seq"
git init --bare -- "${gcrypt_seq_remote_git}" >/dev/null
git init -- "${gcrypt_seq_repo}" >/dev/null
git -C "${gcrypt_seq_repo}" remote add origin "${gcrypt_seq_remote}"
make_commit "${gcrypt_seq_repo}" file.txt "base" "base"
git -C "${gcrypt_seq_repo}" push -f origin main >/dev/null
make_commit "${gcrypt_seq_repo}" file.txt "second" "second"
git -C "${gcrypt_seq_repo}" push origin main >/dev/null
assert_eq "$(git -C "${gcrypt_seq_repo}" rev-parse HEAD)" \
    "$(remote_ref_oid "${gcrypt_seq_remote}" refs/heads/main)" \
    "sequential gcrypt push should fast-forward cleanly"

section "All fast non-fast-forward checks passed"
