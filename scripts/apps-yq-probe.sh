#!/usr/bin/env bash
# Проверка: переменная YQ или бинарь по умолчанию — это github.com/mikefarah/yq v4,
# не PyPI / jq-wrapper yq.

YQBIN="${YQ:-yq}"

if ! { [[ -x "${YQBIN}" ]] || command -v "${YQBIN}" >/dev/null 2>&1; }; then
	echo "✗ исполняемый файл yq не найден: ${YQBIN}. Задайте YQ=/path/to/mikefarah-yq или PATH." >&2
	echo '  Установка: https://github.com/mikefarah/yq#install' >&2
	exit 1
fi

ver=$("$YQBIN" --version 2>&1)
if [[ "$ver" != *mikefarah* ]] && [[ "$ver" != *github.com/mikefarah* ]]; then
	echo "✗ Нужен mikefarah/yq v4+, а не jq-обёртка yq." >&2
	echo "Текущий: $YQBIN — $ver" >&2
	echo 'См.: https://github.com/mikefarah/yq#install' >&2
	exit 1
fi

export YQBIN
