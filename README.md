# zledger

zledger is a command-line tool to manage your finances. It aims to combine the simplicity and power of plain text accounting software such as ([h](https://github.com/simonmichael/hledger))[ledger](https://github.com/ledger/ledger) with built in envelope budgeting akin to [YNAB](https://www.youneedabudget.com/).

## Goal

`zledger budget`:

```
August 2022
-----------

Available...............£      (left over - assigned + activity - future)

Left over from July     £  200 (+available or -overspending)
Assigned this month     £ 2160
Activity this month     £  140 (income - spending)
Assigned in the future  £  300


Category                          Assigned          Activity          Available

General...........................£  410            £- 140            £  270

  Charity                         £   50            £-  20            £   30
  Clothing                        £  100            £-   0            £  100
  Gifts                           £   80            £-  50            £   30
  Home                            £   20            £-  10            £   10
  Medical                         £   50            £-  30            £   20
  Technology                      £  100            £-  25            £   75
  Unexpected                      £   10            £-  15            £-   5


Immediate Obligations.............£  100            £

  Council Tax                     £  100            £ 
  Gas & Electric                  £  100            £ 
  Groceries                       £  100            £ 
  Insurance                       £  100            £ 
  Internet                        £  100            £ 
  Phone                           £  100            £ 
  Rent                            £  100            £ 
  Transportation                  £  100            £ 
  Water                           £  100            £ 


Quality of Life...................£  150            £ 

  Activities                      £   50            £ 
  Eating & Drinking Out           £   50            £ 
  Fitness                         £   50            £ 


Saving............................£ 1500            £ 

  Holidays                        £ 1000            £ 
  New bike                        £  500            £ 
```

`zledger budget -1` will output the budget for the previous month.
`zledger budget +2` will output the budget for two months in the future.
