/***********************************************************************************************************************************
Parse command-line options and command.
***********************************************************************************************************************************/
#include "LibC.h"

/***********************************************************************************************************************************
optionGet - get an option
***********************************************************************************************************************************/
char *
optionGet(const char *szOption, bool bRequired)
{
    if (bRequired)
    {
        // char result[1000];
        // strcpy(result, str1.c_str());
        // return result;
        return "TRUE";
    }

    char *ret = "FALSE";

    return ret;
}