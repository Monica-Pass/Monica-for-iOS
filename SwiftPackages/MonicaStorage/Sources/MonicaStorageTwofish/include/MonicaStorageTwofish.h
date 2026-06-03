#ifndef MONICA_STORAGE_TWOFISH_H
#define MONICA_STORAGE_TWOFISH_H

#include <stddef.h>
#include <stdint.h>

int monica_twofish_decrypt_cbc(
    const uint8_t *key,
    size_t keyLength,
    const uint8_t *iv,
    size_t ivLength,
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output
);

#endif
