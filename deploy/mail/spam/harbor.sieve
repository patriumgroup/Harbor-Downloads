require ["fileinto", "mailbox", "envelope", "variables"];
if envelope :matches "to" "*" {
    set "recipient" "${1}";
    if header :contains "X-Harbor-Junk" "|${recipient}|" {
        fileinto :create "Junk";
        stop;
    }
}
