#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include "common.h"

#define B_ADDR_LEN    6

/*********************************************************************
 * @fn      Util_convertBdAddr2Str
 *
 * @brief   Convert Bluetooth address to string. Only needed when
 *          LCD display is used.
 *
 * @param   pAddr - BD address
 *
 * @return  BD address as a string
 */
char *Util_convertBdAddr2Str(uint8_t *pAddr)
{
  uint8_t     charCnt;
  char        hex[] = "0123456789ABCDEF";
  static char str[(2*B_ADDR_LEN)+3];
  char        *pStr = str;

  *pStr++ = '0';
  *pStr++ = 'x';

  // Start from end of addr
  pAddr += B_ADDR_LEN;

  for (charCnt = B_ADDR_LEN; charCnt > 0; charCnt--)
  {
    *pStr++ = hex[*--pAddr >> 4];
    *pStr++ = hex[*pAddr & 0x0F];
  }
  pStr = NULL;

  return str;
}

/*********************************************************************
 * @fn      Util_convertHex2Str
 *
 * @brief   将HEX转成String，用于转化广播数据和扫描回调数据
 *
 * @param   Hex - Hex
 *          len - Hex len
 *
 * @return  Hex as a string
 */
#define MAX_AD_DATA_LEN 255
char *Util_convertHex2Str(uint8_t *Hex, uint16_t Len)
{
  uint8_t     charCnt;
  char        hex[] = "0123456789ABCDEF";
  static char str[(2*MAX_AD_DATA_LEN)+4];    // 广播数据
  char        *pStr = str;

  *pStr++ = '0';
  *pStr++ = 'x';

  for (charCnt = Len; charCnt > 0; charCnt--)
  {
    *pStr++ = hex[*Hex >> 4];
    *pStr++ = hex[*Hex++ & 0x0F];
  }
  pStr = NULL;

  str[2*Len+2] = '\0';
  return str;
}
