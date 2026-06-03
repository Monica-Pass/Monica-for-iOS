#include "MonicaStorageTwofish.h"
#include "aes.h"
#include <limits.h>

static char monica_hex_nibble(uint8_t value) {
    return (char)(value < 10 ? ('0' + value) : ('a' + (value - 10)));
}

static void monica_hex_encode(const uint8_t *input, size_t length, char *output) {
    for (size_t index = 0; index < length; index++) {
        output[index * 2] = monica_hex_nibble((uint8_t)(input[index] >> 4));
        output[index * 2 + 1] = monica_hex_nibble((uint8_t)(input[index] & 0x0F));
    }
    output[length * 2] = 0;
}

int monica_twofish_decrypt_cbc(
    const uint8_t *key,
    size_t keyLength,
    const uint8_t *iv,
    size_t ivLength,
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output
) {
    if (key == NULL || iv == NULL || input == NULL || output == NULL) {
        return BAD_PARAMS;
    }
    if (keyLength != 32 || ivLength != 16 || inputLength == 0 || inputLength % 16 != 0) {
        return BAD_PARAMS;
    }
    if (inputLength > (size_t)(INT32_MAX / 8)) {
        return BAD_INPUT_LEN;
    }

    char keyHex[65];
    char ivHex[33];
    monica_hex_encode(key, keyLength, keyHex);
    monica_hex_encode(iv, ivLength, ivHex);

    keyInstance keyInstance;
    cipherInstance cipherInstance;
    int keyStatus = makeKey(&keyInstance, DIR_DECRYPT, 256, keyHex);
    if (keyStatus != TRUE) {
        return keyStatus;
    }
    int cipherStatus = cipherInit(&cipherInstance, MODE_CBC, ivHex);
    if (cipherStatus != TRUE) {
        return cipherStatus;
    }
    int decryptedBits = blockDecrypt(
        &cipherInstance,
        &keyInstance,
        (uint8_t *)input,
        (int)(inputLength * 8),
        output
    );
    return decryptedBits == (int)(inputLength * 8) ? TRUE : decryptedBits;
}
