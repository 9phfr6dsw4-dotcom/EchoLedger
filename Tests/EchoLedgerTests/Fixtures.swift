import Foundation

// Synthetic bank files (made-up data) used by the tests. Generated; one string per line.
enum Fixtures {
    struct File {
        let name: String
        let text: String
        var data: Data { Data(text.utf8) }
    }

    static let chaseChecking = File(name: "chase_checking.csv", text: [
        "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n",
        "DEBIT,09/02/2026,\"PINEWOOD APARTMENTS RENT WEB ID: 1234567890\",-1850.00,ACH_DEBIT,3150.00,,\n",
        "CREDIT,09/05/2026,\"ACME CORP PAYROLL PPD ID: 9876543210\",2400.00,ACH_CREDIT,5550.00,,\n",
        "DEBIT,09/08/2026,\"CHASE CREDIT CRD AUTOPAY 9001 PPD ID: 4760039224\",-312.45,ACH_DEBIT,5237.55,,\n",
        "DEBIT,09/10/2026,\"Zelle payment to Alex Rivera JPM99AB12CD\",-60.00,QUICKPAY_DEBIT,5177.55,,\n",
        "DEBIT,09/12/2026,\"ATM WITHDRAWAL 001234 09/12 MAIN ST\",-100.00,ATM,5077.55,,\n",
        "DEBIT,09/15/2026,\"CHECK 1043\",-75.00,CHECK_PAID,5002.55,1043,\n",
    ].joined())

    static let chaseCard = File(name: "Chase9001_Activity20260901_20260930.CSV", text: [
        "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n",
        "09/01/2026,09/02/2026,STARBUCKS STORE 05794,Food & Drink,Sale,-6.45,\n",
        "09/03/2026,09/04/2026,AMAZON MKTPL*AB12C3DE4,Shopping,Sale,-42.99,\n",
        "09/03/2026,09/04/2026,AMAZON MKTPL*ZZ98Y7XW6,Shopping,Sale,-42.99,\n",
        "09/06/2026,09/07/2026,SQ *JOES COFFEE,Food & Drink,Sale,-4.50,\n",
        "09/06/2026,09/07/2026,SQ *JOES COFFEE,Food & Drink,Sale,-4.50,\n",
        "09/08/2026,09/08/2026,AUTOMATIC PAYMENT - THANK,,Payment,312.45,\n",
        "09/10/2026,09/11/2026,AMAZON.COM*RETURN,Shopping,Return,15.00,\n",
        "09/14/2026,09/15/2026,PAYPAL *COINBASEINC 4029357733 CA,Shopping,Sale,-100.00,\n",
        "09/18/2026,09/19/2026,MYSTERY GADGETS LLC,Shopping,Sale,-58.20,\n",
        "09/20/2026,09/21/2026,\"TRATTORIA ROMA, NEW YORK\",Food & Drink,Sale,-88.00,\n",
    ].joined())

    static let appleCard = File(name: "apple_card.csv", text: [
        "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By\n",
        "09/02/2026,09/03/2026,\"UBER *EATS PENDING 8005928996 CA\",\"Uber Eats\",Restaurants,Purchase,23.18,Sam Example\n",
        "09/04/2026,09/05/2026,\"APPLE.COM/BILL ONE APPLE PARK WAY 866-712-7753 CUPERTINO 95014 CA USA\",\"Apple Services\",Other,Purchase,9.99,Sam Example\n",
        "09/09/2026,09/09/2026,\"ACH DEPOSIT INTERNET TRANSFER FROM ACCOUNT ENDING IN 0099\",\"Ach Deposit Internet Transfer From Account Ending In 0099\",Payment,Payment,-150.00,Sam Example\n",
        "09/11/2026,09/12/2026,\"DAILY CASH ADJUSTMENT\",\"Daily Cash Adjustment\",Other,Credit,-1.25,Sam Example\n",
        "09/16/2026,09/17/2026,\"BLUE BOTTLE COFFEE 300 WEBSTER ST OAKLAND 94607 CA USA\",\"Blue Bottle Coffee\",Restaurants,Purchase,7.50,Sam Example\n",
    ].joined())

    static let citi = File(name: "citi.csv", text: [
        "\"Account Number: XXXX-1111\"\n",
        "\"Statement period: 09/01/2026 - 09/30/2026\"\n",
        "Status,Date,Description,Debit,Credit\n",
        "Cleared,09/03/2026,\"SAFEWAY #1234 AUSTIN TX\",54.21,\n",
        "Cleared,09/07/2026,\"SHELL OIL 57444 AUSTIN TX\",48.00,\n",
        "Cleared,09/12/2026,\"ONLINE PAYMENT, THANK YOU\",,-200.00\n",
        "Pending,09/28/2026,\"NETFLIX.COM\",15.49,\n",
        "Cleared,09/20/2026,\"TARGET 00012345 DENVER CO\",,-12.00\n",
    ].joined())

    static let capitalOne = File(name: "capital_one.csv", text: [
        "Transaction Date,Posted Date,Card No.,Description,Category,Debit,Credit\n",
        "2026-09-04,2026-09-05,9876,KOHLS 0714 DENVER CO,Merchandise,64.10,\n",
        "2026-09-15,2026-09-15,9876,CAPITAL ONE ONLINE PYMT,Payment/Credit,,64.10\n",
        "2026-09-20,2026-09-21,9876,INTEREST CHARGE:PURCHASES,Fee/Interest Charge,2.31,\n",
    ].joined())

    static let wellsFargoChecking = File(name: "wells_fargo_checking.csv", text: [
        "\"DATE\",\"DESCRIPTION\",\"AMOUNT\",\"CHECK #\",\"STATUS\"\r\n",
        "\"09/01/2026\",\"PURCHASE AUTHORIZED ON 08/30 STARBUCKS STORE 12345 AUSTIN TX S386248709542601 CARD 1234\",\"-5.75\",\"\",\"Posted\"\r\n",
        "\"09/03/2026\",\"ACME CLINIC PAYROLL 090326 XXXXX1234\",\"1800.00\",\"\",\"Posted\"\r\n",
        "\"09/05/2026\",\"ZELLE TO RIVERA ALEX ON 09/05 REF # PP0ABCDEF\",\"-40.00\",\"\",\"Posted\"\r\n",
        "\"09/08/2026\",\"ONLINE TRANSFER TO WAY2SAVE SAVINGS XXXXXX9999 REF #IB0X9Z ON 09/08/26\",\"-100.00\",\"\",\"Posted\"\r\n",
        "\"09/09/2026\",\"RECURRING PAYMENT AUTHORIZED ON 09/08 NETFLIX.COM LOS GATOS CA S306252123456789 CARD 1234\",\"-15.49\",\"\",\"Posted\"\r\n",
        "\"09/29/2026\",\"PURCHASE AUTHORIZED ON 09/28 RALEY'S #123 DENVER CO P000000123456789 CARD 1234\",\"-32.10\",\"\",\"Pending\"\r\n",
    ].joined())

    static let wellsFargoCard = File(name: "wells_fargo_card.csv", text: [
        "\"DATE\",\"DESCRIPTION\",\"AMOUNT\",\"CHECK #\",\"STATUS\"\n",
        "\"09/02/2026\",\"ULTA.COM #1234 BOLINGBROOK IL\",\"-28.40\",\"\",\"Posted\"\n",
        "\"09/14/2026\",\"ONLINE PAYMENT THANK YOU\",\"120.00\",\"\",\"Posted\"\n",
        "\"09/25/2026\",\"INTEREST CHARGE ON PURCHASES\",\"-3.12\",\"\",\"Posted\"\n",
    ].joined())

    static let comenity = File(name: "comenity.txt", text: [
        "09/05/2026\t$45.00\tMACYS.COM\tpurchase\n",
        "09/18/2026\t-$45.00\tPAYMENT - THANK YOU\tpayment\n",
        "09/25/2026\t$1.85\tINTEREST CHARGED\tinterest charged\n",
    ].joined())

    static let invalid = File(name: "invalid.csv", text: [
        "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n",
        "09/01/2026,09/02/2026,GOOD ROW,Shopping,Sale,-10.00,\n",
        "13/45/2026,09/02/2026,BAD DATE,Shopping,Sale,-10.00,\n",
        "09/03/2026,09/04/2026,BAD AMOUNT,Shopping,Sale,12.345,\n",
        "09/04/2026,09/05/2026,,Shopping,Sale,-3.00,\n",
        "\n",
        "09/06/2026,09/07/2026,NO AMOUNT,Shopping,Sale,,\n",
    ].joined())

    static let unknown = File(name: "unknown.csv", text: [
        "Foo,Bar,Baz\n",
        "1,2,3\n",
    ].joined())

    static let chaseCardOverlap = File(name: "chase_card_overlap.csv", text: [
        "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n",
        "09/18/2026,09/19/2026,MYSTERY GADGETS LLC,Shopping,Sale,-58.20,\n",
        "09/20/2026,09/21/2026,TRATTORIA ROMA NEW YORK NY,Food & Drink,Sale,-88.00,\n",
        "10/02/2026,10/03/2026,STARBUCKS STORE 05794,Food & Drink,Sale,-6.45,\n",
        "10/04/2026,10/05/2026,NETFLIX.COM,Shopping,Sale,-15.49,\n",
    ].joined())

    static let citiOctober = File(name: "citi_october.csv", text: [
        "Status,Date,Description,Debit,Credit\n",
        "Cleared,09/29/2026,\"NETFLIX.COM 866-579-7172 CA\",15.49,\n",
        "Cleared,10/03/2026,\"SAFEWAY #1234 AUSTIN TX\",20.00,\n",
    ].joined())

    static let chaseCardOctober = File(name: "chase_card_october.csv", text: [
        "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n",
        "10/12/2026,10/13/2026,\"TRATTORIA ROMA, NEW YORK\",Food & Drink,Sale,-42.00,\n",
    ].joined())

    static let creditUnion = File(name: "credit_union.csv", text: [
        "Credit Union Export\n",
        "Date,Memo,Withdrawal,Deposit,Balance\n",
        "2026-09-02,COFFEE CART 9,4.50,,995.50\n",
        "2026-09-03,PAYROLL ACME,,1200.00,2195.50\n",
        "2026-09-05,GROCERY STORE 12,82.10,,2113.40\n",
    ].joined())

    static let storeCard = File(name: "store_card.csv", text: [
        "Date,Details,Charge\n",
        "09/01/2026,STORE A,25.00\n",
        "09/02/2026,STORE B,30.00\n",
        "09/03/2026,STORE C,12.00\n",
        "09/04/2026,STORE D,8.00\n",
        "09/05/2026,STORE E,40.00\n",
        "09/10/2026,PAYMENT RECEIVED,-115.00\n",
    ].joined())

    static let noHeader = File(name: "no_header.csv", text: [
        "09/01/2026,LOCAL STORE A,-25.00\n",
        "09/02/2026,LOCAL STORE B,-30.00\n",
        "09/03/2026,REFUND LOCAL STORE A,5.00\n",
    ].joined())

    /// The household's September files, in import order, with the owner of each account.
    static let september: [(file: File, owner: String?)] = [
        (file: chaseChecking, owner: "Sam"),
        (file: chaseCard, owner: "Sam"),
        (file: appleCard, owner: "Sam"),
        (file: citi, owner: nil),
        (file: capitalOne, owner: "Alex"),
        (file: wellsFargoChecking, owner: "Alex"),
        (file: wellsFargoCard, owner: "Alex"),
        (file: comenity, owner: "Alex"),
    ]
}
