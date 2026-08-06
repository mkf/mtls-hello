*** Settings ***
Library         MtlsLibrary.py
Test Setup      Setup Test Environment
Test Teardown   Teardown Test Environment

*** Test Cases ***
Drop And Fetch Roundtrip
    Trust Two Identities
    # Alice drops a file
    ${data}=    Evaluate    b'hello from alice'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    alice
    Should Be Equal As Integers    ${status}    201
    # Alice reads it back
    ${s}    ${h}    ${body}=    Mtls Get Drop    notes.txt    alice
    Should Be Equal As Integers    ${s}    200
    Should Be Equal    ${body}    ${{b'hello from alice'}}
    # Bob drops a different file under his own prefix
    ${data2}=    Evaluate    b'hello from bob'
    ${status2}=    Mtls Drop Body    notes.txt    ${data2}    bob
    Should Be Equal As Integers    ${status2}    201
    # Bob reads his own file
    ${s2}    ${h2}    ${body2}=    Mtls Get Drop    notes.txt    bob
    Should Be Equal As Integers    ${s2}    200
    Should Be Equal    ${body2}    ${{b'hello from bob'}}

Cross-Host 403 Isolation
    Trust Two Identities
    ${data}=    Evaluate    b'alice secret'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    alice
    Should Be Equal As Integers    ${status}    201
    # Alice tries to read bob's prefix → 403
    ${s}    ${h}    ${body}=    Mtls Get Drop Cross Host    bob.test    notes.txt    alice
    Should Be Equal As Integers    ${s}    403

Untrusted Client 401
    # Evil cert is generated but NOT trusted
    ${data}=    Evaluate    b'evil data'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    evil
    Should Be Equal As Integers    ${status}    401

Path Traversal Rejected
    Trust Two Identities
    ${data}=    Evaluate    b'traversal test'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    alice
    Should Be Equal As Integers    ${status}    201
    # Alice tries a traversal path — should be rejected or canonicalized
    ${s}    ${h}    ${body}=    Mtls Get Drop Cross Host    alice.test    ../../etc/passwd    alice
    Should Be True    ${s} >= 400
    # Alice's legitimate file should still be readable
    ${s2}=    Mtls Get Drop Status    notes.txt    alice
    Should Be Equal As Integers    ${s2}    200

HEAD Returns Headers No Body
    Trust Two Identities
    ${data}=    Evaluate    b'head test data'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    alice
    Should Be Equal As Integers    ${status}    201
    ${s}    ${h}    ${body}=    Mtls Head Drop    notes.txt    alice
    Should Be True    ${s} == 200 or ${s} == 204
    Length Should Be    ${body}    0
    Should Contain    ${h}    etag

DELETE File Works
    Trust Two Identities
    ${data}=    Evaluate    b'delete me'
    ${status}=    Mtls Drop Body    notes.txt    ${data}    alice
    Should Be Equal As Integers    ${status}    201
    ${ds}=    Mtls Delete Drop    notes.txt    alice
    Should Be Equal As Integers    ${ds}    204
    ${s}=    Mtls Get Drop Status    notes.txt    alice
    Should Be Equal As Integers    ${s}    404

MKCOL COPY MOVE Roundtrip
    Trust Two Identities
    # MKCOL
    ${ms}=    Mtls Mkcol Drop    archive    alice
    Should Be True    ${ms} == 201 or ${ms} == 405
    # Drop a file inside
    ${data}=    Evaluate    b'archive content'
    ${ds}=    Mtls Drop Body    archive/x.bin    ${data}    alice
    Should Be True    ${ds} == 201
    # COPY
    ${cs}=    Mtls Copy Drop    archive/x.bin    archive/x.copy.bin    alice
    Should Be True    ${cs} == 201 or ${cs} == 204
    # MOVE
    ${ms2}=    Mtls Move Drop    archive/x.bin    archive/x.moved.bin    alice
    Should Be True    ${ms2} == 201 or ${ms2} == 204
    # Verify the copy exists
    ${s}    ${h}    ${body}=    Mtls Get Drop    archive/x.copy.bin    alice
    Should Be Equal As Integers    ${s}    200
