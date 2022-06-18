---
title:  12.详解Condition的线程通信机制
description:  详解Condition的线程通信机制
date: 2022-04-03 16:15:00
prev: ./11、深入理解读写锁ReentrantReadWriteLock
next: ./13、LockSupport工具
tags:
- 'Java'
- 'Java并发编程'
- 'JUC'
categories:
- '技术'
---

::: tip 说明

详解Condition的线程通信机制

:::

<!-- more -->

[[toc]]

# 详解Condition的线程通信机制

# 1、Condition简介

任何一个java对象都天然继承于Object类，在线程间实现通信的往往会应用到Object的几个方法，比如wait(),wait(long timeout),wait(long timeout, int nanos)与notify(),notifyAll()几个方法实现等待/通知机制，同样的， 在java Lock体系下依然会有同样的方法实现等待/通知机制。

从整体上来看**Object的wait和notify/notify是与对象监视器配合完成线程间的等待/通知机制，而Condition与Lock配合完成等待通知机制，前者是java底层级别的，后者是语言级别的，具有更高的可控制性和扩展性**。两者除了在使用方式上不同外，在**功能特性**上还是有很多的不同：

 ![image-20220408170820826](image/image-20220408170820826.png ":size=70%")

参照Object的wait和notify/notifyAll方法，Condition也提供了同样的方法：

> **针对Object的wait方法**

1. `void await() throws InterruptedException`：当前线程进入等待状态，如果其他线程调用condition的signal或者signalAll方法并且当前线程被选中唤醒；如果在等待状态中被中断会抛出被中断异常，如果当前等待线程从await()方法返回，那么表明该线程已经获取了Condition对象所对应的锁。
2. `long awaitNanos(long nanosTimeout)`：当前线程进入等待状态直到被通知，中断或者**超时**；
3. `boolean await(long time, TimeUnit unit)throws InterruptedException`：同第二种，支持自定义时间单位
4. `boolean awaitUntil(Date deadline) throws InterruptedException`：当前线程进入等待状态直到被通知，中断或者**到了某个时间**

> **针对Object的notify/notifyAll方法**

1. `void signal()`：唤醒一个等待在condition上的线程，将该线程从**等待队列**中转移到**同步队列**中，如果在同步队列中能够竞争到Lock则可以从等待方法中返回。
2. `void signalAll()`：与1的区别在于能够唤醒所有等待在condition上的线程

既然功能都一样，问什么还需要使用Condition呢？简单来说，Condition需要和Lock一起使用，在不使用Lock时，使用关键字`synchronized`时的代码如下：

```java
synchronized(obj){
    obj.wait();
}
synchronized(obj){
    obj.notify();
}
```

使用Lock时的代码如下：

```java
lock.lock();
condition.await();
lock.unlock();

lock.lock();
condition.signal();
lock.unlock();
```

从代码上可以看出，使用`synchronized`关键字时，所有没有获取锁的线程都会等待，这时相当于只有1个等待队列；而在实际应用中可能有时需要多个等待队列，比如ReadLock和WriteLock。Lock中的等待队列和Condition中的等待队列是分开的，例如在独占模式下，Lock的独占保证了在同一时刻只会有一个线程访问临界区，也就是lock()方法返回后，Condition中的等待队列保存着被阻塞的线程，也就是调用await()方法后阻塞的线程。所以使用lock比使用`synchronized`关键字更加灵活。

# 2、Condition的使用

在Condition接口的javadoc中，有一个很好的例子（有界缓冲区）来使用Condition，代码如下：

```java
class BoundedBuffer {
    final Lock lock = new ReentrantLock();
    final Condition notFull  = lock.newCondition();
    final Condition notEmpty = lock.newCondition();

    final Object[] items = new Object[100];
    int putptr, takeptr, count;

    public void put(Object x) throws InterruptedException {
        lock.lock();
        try {
            while (count == items.length)
                notFull.await();
            items[putptr] = x;
            if (++putptr == items.length) putptr = 0;
            ++count;
            notEmpty.signal();
        } finally {
            lock.unlock();
        }
    }

    public Object take() throws InterruptedException {
        lock.lock();
        try {
            while (count == 0)
                notEmpty.await();
            Object x = items[takeptr];
            if (++takeptr == items.length) takeptr = 0;
            --count;
            notFull.signal();
            return x;
        } finally {
            lock.unlock();
        }
    }
}
```

代码很简单，定义了一个数组items，put用于向items中添加数据，take用于从items中取出数据，count代表当前items中存放了多少个对象，putptr表示下一个需要添加的索引，takeptr表示下一个需要取出的索引，这样就实现了数组的循环添加和取出数据的功能。put和take的具体功能如下：

- **put**
  1. 当count与items的长度相同时，表示数组已满，则调用`notFull.await()`来等待同时释放了当前线程的锁；
  2. 当线程被唤醒时，将x添加到putptr索引的位置；
  3. 如果当前putptr的位置是最后一个，则下一个索引的位置从0开始；
  4. 调用`notEmpty.signal();`通知其他线程可以从数组中取出数据了。
- **take**
  1. 当count为0时，表示数组是空的，则调用`notEmpty.await()`来等待同时释放了当前线程的锁；
  2. 当线程被唤醒时，将x添加到takeptr索引的位置；
  3. 如果当前takeptr的位置是最后一个，则下一个索引的位置从0开始；
  4. 调用`notFull.signal();`通知其他线程可以向数组中添加数据了。

# 3、Condition实现原理分析

## 等待队列

要想能够深入的掌握condition还是应该知道它的实现原理，现在我们一起来看看condiiton的源码。创建一个condition对象是通过`lock.newCondition()`，而这个方法实际上是会new出一个**ConditionObject**对象，该类是AQS的一个内部类。前面我们说过，condition是要和lock配合使用的也就是condition和Lock是绑定在一起的，而lock的实现原理又依赖于AQS，自然而然ConditionObject作为AQS的一个内部类无可厚非。

我们知道在锁机制的实现上，AQS内部维护了一个同步队列，如果是独占式锁的话，所有获取锁失败的线程的尾插入到**同步队列**，同样的，condition内部也是使用同样的方式，内部维护了一个 **等待队列**，如果一个线程调用了Condition.await()方法，那么该线程将会释放锁、构造成节点加入等待队列并进入等待状态。事实上，节点的定义复用了同步器（AQS）中节点的定义，也就是说，同步队列和等待队列中节点类型都是同步器的静态内部类`AbstractQueuedSynchronizer.Node`。

通过前面对AQS同步队列的学习，我们知道同步队列是一个双向队列，而事实上Condition的**等待队列是一个单向队列**，接下来我们用一个demo，通过debug进去看是不是符合我们的猜想：

```java
public static void main(String[] args) {
    for (int i = 0; i < 10; i++) {
        Thread thread = new Thread(() -> {
            lock.lock();
            try {
                condition.await();
            } catch (InterruptedException e) {
                e.printStackTrace();
            }finally {
                lock.unlock();
            }
        });
        thread.start();
    }
}
```

这段代码没有任何实际意义，甚至很臭，只是想说明下我们刚才所想的。新建了10个线程，没有线程先获取锁，然后调用condition.await方法释放锁将当前线程加入到等待队列中，通过debug控制当走到第10个线程的时候查看`firstWaiter`即等待队列中的头结点，debug模式下情景图如下：

 ![debug模式下情景图.png](image/debug模式下情景图.png ":size=60%")

从这个图我们可以很清楚的看到这样几点：

1. 调用condition.await方法后线程依次尾插入到等待队列中，如图队列中的线程引用依次为Thread-0,Thread-1,Thread-2....Thread-8；
2. 等待队列是一个单向队列（因为Node节点中的prev和next都为null）。

而事实上，等待队列的基本结构图也正是如此：

 ![image-20220408175317598](image/image-20220408175317598.png ":size=60%")

如图所示，Condition拥有首尾节点的引用，而新增节点只需要将原有的尾节点nextWaiter指向它，并且更新尾节点即可。上述节点引用更新的过程并没有使用CAS保证，原因在于调用await()方法的线程必定是获取了锁的线程，也就是说该过程是由锁来保证线程安全的。

同时还有一点需要注意的是：我们可以多次调用lock.newCondition()方法创建多个condition对象，也就是一个lock可以持有多个等待队列。而在之前利用Object的方式实际上是指在**对象Object对象监视器上只能拥有一个同步队列和一个等待队列，而并发包中的Lock拥有一个同步队列和多个等待队列**。示意图如下：

 ![image-20220408175543674](image/image-20220408175543674.png ":size=60%")

如图所示，Condition的实现是同步器的内部类，因此每个Condition实例都能够访问同步器提供的方法，相当于每个Condition都拥有所属同步器的引用。

## await方法

**当调用condition.await()方法后会使得当前获取lock的线程进入到等待队列，如果该线程能够从await()方法返回的话一定是该线程获取了与condition相关联的lock**。await()方法源码为：

```java
public final void await() throws InterruptedException {
    if (Thread.interrupted())
        throw new InterruptedException();
    // 1. 将当前线程包装成Node，尾插入到等待队列中
    Node node = addConditionWaiter();
    // 2. 释放当前线程所占用的lock，在释放的过程中会唤醒同步队列中的下一个节点
    int savedState = fullyRelease(node);
    int interruptMode = 0;
    while (!isOnSyncQueue(node)) {
        // 3. 当前线程进入到等待状态
        LockSupport.park(this);
        if ((interruptMode = checkInterruptWhileWaiting(node)) != 0)
            break;
    }
    // 4. 自旋等待获取到同步状态（即获取到lock）
    if (acquireQueued(node, savedState) && interruptMode != THROW_IE)
        interruptMode = REINTERRUPT;
    if (node.nextWaiter != null) // clean up if cancelled
        unlinkCancelledWaiters();
    // 5. 处理被中断的情况
    if (interruptMode != 0)
        reportInterruptAfterWait(interruptMode);
}
```

代码的主要逻辑**请看注释**，我们都知道**当当前线程调用condition.await()方法后，会使得当前线程释放lock然后加入到等待队列中，直至被signal/signalAll后会使得当前线程从等待队列中移至到同步队列中去，直到获得了lock后才会从await方法返回，或者在等待时被中断会做中断处理**。

那么关于这个实现过程我们只要弄清这样几个问题：

1. 是怎样将当前线程添加到等待队列中去的？
2. 释放锁的过程？
3. 怎样才能从await方法退出？

## addConditionWaiter方法

在第1步中调用addConditionWaiter将当前线程添加到等待队列中，该方法源码为：

```java
private Node addConditionWaiter() {
    Node t = lastWaiter;
    // If lastWaiter is cancelled, clean out.
    if (t != null && t.waitStatus != Node.CONDITION) {
        unlinkCancelledWaiters();
        t = lastWaiter;
    }
    //将当前线程包装成Node
    Node node = new Node(Thread.currentThread(), Node.CONDITION);
    if (t == null)
        firstWaiter = node;
    else
        //尾插入
        t.nextWaiter = node;
    //更新lastWaiter
    lastWaiter = node;
    return node;
}
```

这段代码就很容易理解了，将当前节点包装成Node，如果等待队列的firstWaiter为null的话（等待队列为空队列），则将firstWaiter指向当前的Node,否则，更新lastWaiter(尾节点)即可。就是**通过尾插入的方式将当前线程封装的Node插入到等待队列中即可**，同时可以看出等待队列是一个**不带头结点的链式队列**，之前我们学习AQS时知道同步队列**是一个带头结点的链式队列**，这是两者的一个区别。

## fullyRelease方法

将当前节点插入到等待对列之后，会使当前线程释放lock，由fullyRelease方法实现，fullyRelease源码为：

```java
final int fullyRelease(Node node) {
    boolean failed = true;
    try {
        int savedState = getState();
        if (release(savedState)) {
            //成功释放同步状态
            failed = false;
            return savedState;
        } else {
            //不成功释放同步状态抛出异常
            throw new IllegalMonitorStateException();
        }
    } finally {
        if (failed)
            node.waitStatus = Node.CANCELLED;
    }
}
```

这段代码也很容易理解了，**调用AQS的模板方法release方法释放AQS的同步状态并且唤醒在同步队列中头结点的后继节点引用的线程**，如果释放成功则正常返回，若失败的话就抛出异常。

最后一个问题：怎样从await方法退出？现在回过头再来看await方法有这样一段逻辑：

```java
while (!isOnSyncQueue(node)) {
	// 3. 当前线程进入到等待状态
    LockSupport.park(this);
    if ((interruptMode = checkInterruptWhileWaiting(node)) != 0)
        break;
}
```

很显然，当线程第一次调用condition.await()方法时，会进入到这个while()循环中，然后通过LockSupport.park(this)方法使得当前线程进入等待状态，那么要想退出这个await方法第一个前提条件自然而然的是要先退出这个while循环，出口就只剩下两个地方：**1. 逻辑走到break退出while循环；2. while循环中的逻辑判断为false**。再看代码出现第1种情况的条件是当前等待的线程被中断后代码会走到break退出，第二种情况是当前节点被移动到了同步队列中（即另外线程调用的condition的signal或者signalAll方法），while中逻辑判断为false后结束while循环。

## await总结

总结下，就是**当前线程被中断或者调用condition.signal/condition.signalAll方法当前节点移动到了同步队列后** ，这是当前线程退出await方法的前提条件。当退出while循环后就会调用`acquireQueued(node, savedState)`，这个方法在介绍AQS的底层实现时说过了，该方法的作用是在**自旋过程中线程不断尝试获取同步状态，直至成功（线程获取到lock）**。await方法示意图如下图：

 ![image-20220408181652588](image/image-20220408181652588.png ":size=60%")

如图，调用condition.await方法的线程必须是已经获得了lock，也就是当前线程是同步队列中的头结点。调用该方法后会使得当前线程所封装的Node尾插入到等待队列中。

> 超时机制的支持

condition还额外支持了超时机制，使用者可调用方法awaitNanos,awaitUtil。这两个方法的实现原理，基本上与AQS中的tryAcquire方法如出一辙，关于tryAcquire可以仔细阅读[这篇文章的第3.4部分](https://juejin.im/post/5aeb07ab6fb9a07ac36350c8#heading-6)。

> 不响应中断的支持

要想不响应中断可以调用condition.awaitUninterruptibly()方法，该方法的源码为：

```java
public final void awaitUninterruptibly() {
    Node node = addConditionWaiter();
    int savedState = fullyRelease(node);
    boolean interrupted = false;
    while (!isOnSyncQueue(node)) {
        LockSupport.park(this);
        if (Thread.interrupted())
            interrupted = true;
    }
    if (acquireQueued(node, savedState) || interrupted)
        selfInterrupt();
}
```

这段方法与上面的await方法基本一致，只不过减少了对中断的处理，并省略了reportInterruptAfterWait方法抛被中断的异常。

## signal/signalAll实现原理

**调用condition的signal或者signalAll方法可以将等待队列中等待时间最长的节点移动到同步队列中**，使得该节点能够有机会获得lock。按照等待队列是先进先出（FIFO）的，所以等待队列的头节点必然会是等待时间最长的节点，也就是每次调用condition的signal方法是将头节点移动到同步队列中。我们来通过看源码的方式来看这样的猜想是不是对的，signal方法源码为：

```java
public final void signal() {
    //1. 先检测当前线程是否已经获取lock
    if (!isHeldExclusively())
        throw new IllegalMonitorStateException();
    //2. 获取等待队列中第一个节点，之后的操作都是针对这个节点
	Node first = firstWaiter;
    if (first != null)
        doSignal(first);
}
```

signal方法首先会检测当前线程是否已经获取lock，如果没有获取lock会直接抛出异常，如果获取的话再得到等待队列的头指针引用的节点，之后的操作的doSignal方法也是基于该节点。

## doSignal方法

下面我们来看看doSignal方法做了些什么事情，doSignal方法源码为：

```java
private void doSignal(Node first) {
    do {
        if ( (firstWaiter = first.nextWaiter) == null)
            lastWaiter = null;
		//1. 将头结点从等待队列中移除
        first.nextWaiter = null;
		//2. while中transferForSignal方法对头结点做真正的处理
    } while (!transferForSignal(first) &&
             (first = firstWaiter) != null);
}
```

具体逻辑请看注释，真正对头节点做处理的逻辑在**transferForSignal**方放

## transferForSignal方法

该方法源码为：

```java
final boolean transferForSignal(Node node) {
    /*
     * If cannot change waitStatus, the node has been cancelled.
     */
	//1. 更新状态为0
    if (!compareAndSetWaitStatus(node, Node.CONDITION, 0))
        return false;

    /*
     * Splice onto queue and try to set waitStatus of predecessor to
     * indicate that thread is (probably) waiting. If cancelled or
     * attempt to set waitStatus fails, wake up to resync (in which
     * case the waitStatus can be transiently and harmlessly wrong).
     */
	//2.将该节点移入到同步队列中去
    Node p = enq(node);
    int ws = p.waitStatus;
    if (ws > 0 || !compareAndSetWaitStatus(p, ws, Node.SIGNAL))
        LockSupport.unpark(node.thread);
    return true;
}
```

关键逻辑请看注释，这段代码主要做了两件事情：

1. 将头结点的状态更改为CONDITION；

2. 调用enq方法，将该节点尾插入到同步队列中。

## signal总结

**总结就是：**

- 通过调用同步器的enq(Node node)方法，等待队列中的头节点线程安全地移动到同步队列。当节点移动到同步队列后，当前线程再使用LockSupport唤醒该节点的线程。

- 被唤醒后的线程，将从await()方法中的while循环中退出（isOnSyncQueue(Node node)方法返回true，节点已经在同步队列中），进而调用同步器的acquireQueued()方法加入到获取同步状态的竞争中。
- 成功获取同步状态（或者说锁）之后，被唤醒的线程将从先前调用的await()方法返回，此时该线程已经成功地获取了锁。

signal执行示意图如下图：

 ![image-20220409155823763](image/image-20220409155823763.png ":size=60%")

> signalAll

sigllAll与sigal方法的区别体现在doSignalAll方法上，前面我们已经知道**doSignal方法只会对等待队列的头节点进行操作**，而doSignalAll的源码为：

```java
private void doSignalAll(Node first) {
    lastWaiter = firstWaiter = null;
    do {
        Node next = first.nextWaiter;
        first.nextWaiter = null;
        transferForSignal(first);
        first = next;
    } while (first != null);
}
```

该方法只不过时间等待队列中的每一个节点都移入到同步队列中，即“通知”当前调用condition.await()方法的每一个线程。

# 4、await与signal/signalAll的结合思考

文章开篇提到等待/通知机制，通过使用condition提供的await和signal/signalAll方法就可以实现这种机制，而这种机制能够解决最经典的问题就是“生产者与消费者问题”，关于“生产者消费者问题”之后会用单独的一篇文章进行讲解，这也是面试的高频考点。await和signal和signalAll方法就像一个开关控制着线程A（等待方）和线程B（通知方）。它们之间的关系可以用下面一个图来表现得更加贴切：

 ![condition下的等待通知机制.png](image/condition下的等待通知机制.png)

如图，**线程awaitThread先通过lock.lock()方法获取锁成功后调用了condition.await方法进入等待队列，而另一个线程signalThread通过lock.lock()方法获取锁成功后调用了condition.signal或者signalAll方法，使得线程awaitThread能够有机会移入到同步队列中，当其他线程释放lock后使得线程awaitThread能够有机会获取lock，从而使得线程awaitThread能够从await方法中退出执行后续操作。如果awaitThread获取lock失败会直接进入到同步队列**。

# 5、一个例子

我们用一个很简单的例子说说condition的用法：

```java
public class AwaitSignal {
    private static ReentrantLock lock = new ReentrantLock();
    private static Condition condition = lock.newCondition();
    private static volatile boolean flag = false;

    public static void main(String[] args) {
        Thread waiter = new Thread(new waiter());
        waiter.start();
        Thread signaler = new Thread(new signaler());
        signaler.start();
    }

    static class waiter implements Runnable {

        @Override
        public void run() {
            lock.lock();
            try {
                while (!flag) {
                    System.out.println(Thread.currentThread().getName() + "当前条件不满足等待");
                    try {
                        condition.await();
                    } catch (InterruptedException e) {
                        e.printStackTrace();
                    }
                }
                System.out.println(Thread.currentThread().getName() + "接收到通知条件满足");
            } finally {
                lock.unlock();
            }
        }
    }

    static class signaler implements Runnable {

        @Override
        public void run() {
            lock.lock();
            try {
                flag = true;
                condition.signalAll();
            } finally {
                lock.unlock();
            }
        }
    }
}
```

输出结果为：

```
Thread-0当前条件不满足等待
Thread-0接收到通知，条件满足
```

开启了两个线程waiter和signaler，waiter线程开始执行的时候由于条件不满足，执行condition.await方法使该线程进入等待状态同时释放锁，signaler线程获取到锁之后更改条件，并通知所有的等待线程后释放锁。这时，waiter线程获取到锁，并由于signaler线程更改了条件此时相对于waiter来说条件满足，继续执行。

> 参考文献

《java并发编程的艺术》

[深入理解AbstractQueuedSynchronizer（三）](http://www.ideabuffer.cn/2017/03/20/%E6%B7%B1%E5%85%A5%E7%90%86%E8%A7%A3AbstractQueuedSynchronizer%EF%BC%88%E4%B8%89%EF%BC%89/)

