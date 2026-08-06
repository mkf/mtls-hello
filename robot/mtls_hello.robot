*** Settings ***
Library    MtlsLibrary.py
Suite Setup    Setup Test Environment
Suite Teardown    Teardown Test Environment

*** Test Cases ***
Reject Client Without Certificate
    ${rc} =    Mtls Get Without Cert    /nope
    Should Not Be Equal As Integers    ${rc}    0

Reject Untrusted Client Certificate
    ${rc} =    Mtls Get With Untrusted Cert    /evil
    Should Not Be Equal As Integers    ${rc}    0

Echo Path For Trusted Client
    ${output} =    Mtls Get    /hello%20world
    Should Be Equal    ${output}    hello world

Capture Untrusted Cert In Purgatory
    Remove All Purgatory Files
    ${rc} =    Mtls Get With Untrusted Cert    /nope
    Should Not Be Equal As Integers    ${rc}    0
    ${files} =    Wait For Purgatory File
    Length Should Be    ${files}    1
    Should Match Regexp    ${files}[0]    evil\.[0-9a-f]{64}\.crt

Promote Captured Cert And Trust
    Remove All Purgatory Files
    Mtls Get With Untrusted Cert    /nope
    Promote Captured Cert
    ${output} =    Mtls Get With Evil Cert    /hello
    Should Be Equal    ${output}    hello
