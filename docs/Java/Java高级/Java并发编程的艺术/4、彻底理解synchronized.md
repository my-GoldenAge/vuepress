---
title: 4.彻底理解synchronized
description: 彻底理解synchronized
date: 2022-03-28 15:15:00
prev: ./3、Java内存模型以及happens-before
next: ./5、彻底理解volatile
tags:
- 'Java'
- 'Java并发编程'
- 'JUC'
categories:
- '技术'
---

::: tip 说明

彻底理解synchronized

:::

<!-- more -->

[[toc]]
# 彻底理解synchronized

## 1、CAS操作

### 什么是 CAS ?

使用锁时，线程获取锁是一种**悲观锁策略**，即假设每一次执行临界区代码都会产生冲突，所以当前线程获取到锁的时候同时也会阻塞其他线程获取该锁。而 CAS 操作（又称为无锁操作）是一种**乐观锁策略**，它假设所有线程访问共享资源的时候不会出现冲突，既然不会出现冲突自然而然就不会阻塞其他线程的操作。因此，线程就不会出现阻塞停顿的状态。那么，如果出现冲突了怎么办？无锁操作是使用**CAS**(compare and swap)又叫做比较交换来鉴别线程是否出现冲突，出现冲突就重试当前操作直到没有冲突为止。

### CAS的操作过程

CAS比较交换的过程可以通俗的理解为CAS(V,O,N)，包含三个值分别为：

> **V：内存地址存放的实际值**
>
> **O：预期的值（旧值）**
>
> **N：更新的新值**

当 V 和 O 相同时，也就是说旧值和内存中实际的值相同表明该值没有被其他线程更改过，即该旧值 O 就是目前来说最新的值了，自然而然可以将新值 N 赋值给 V 。反之，V 和 O 不相同，表明该值已经被其他线程改过了则该旧值 O 不是最新版本的值了，所以不能将新值 N赋给 V，返回 V 即可。当多个线程使用 CAS 操作一个变量是，只有一个线程会成功，并成功更新，其余会失败。失败的线程会重新尝试，当然也可以选择挂起线程。

CAS 的实现需要硬件指令集的支撑，在 JDK1.5 后虚拟机才可以使用处理器提供的 **CMPXCHG** 指令实现。

> Synchronized VS CAS

元老级的 Synchronized (未优化前)最主要的问题是：在存在线程竞争的情况下会出现线程阻塞和唤醒锁带来的性能问题，因为这是一种互斥同步（阻塞同步）。而 CAS 并不是武断的将线程挂起，当 CAS 操作失败后会进行一定的尝试，而非进行耗时的挂起唤醒的操作，因此也叫做非阻塞同步。这是两者主要的区别。

### CAS的应用场景

在 J.U.C 包中利用 CAS 实现类有很多，可以说是支撑起整个 concurrency 包的实现，在 Lock 实现中会有 CAS 改变 state 变量，在atomic 包中的实现类也几乎都是用 CAS 实现，关于这些具体的实现场景在之后会详细聊聊。

### CAS的问题

**1. ABA问题**

因为 CAS 会检查旧值有没有变化，这里存在这样一个有意思的问题。比如一个旧值 A 变为了成 B，然后再变成 A，刚好在做 CAS 时检查发现旧值并没有变化依然为 A，但是实际上的确发生了变化。解决方案可以沿袭数据库中常用的乐观锁方式，添加一个版本号可以解决。原来的变化路径 A->B->A 就变成了 1A->2B->3C 。java 这么优秀的语言，当然在 java 1.5 后的 atomic 包中提供了AtomicStampedReference 来解决 ABA 问题，解决思路就是这样的。

**2. 自旋时间过长**

使用 CAS 时非阻塞同步，也就是说不会将线程挂起，会自旋（无非就是一个死循环）进行下一次尝试，如果这里自旋时间过长对性能是很大的消耗。如果 JVM 能支持处理器提供的 pause 指令，那么在效率上会有一定的提升。

**3. 只能保证一个共享变量的原子操作**

当对一个共享变量执行操作时 CAS 能保证其原子性，如果对多个共享变量进行操作，CAS 就不能保证其原子性。有一个解决方案是利用对象整合多个共享变量，即一个类中的成员变量就是这几个共享变量。然后将这个对象做 CAS 操作就可以保证其原子性。atomic 中提供了 AtomicReference 来保证引用对象之间的原子性。

## 2、synchronized实现原理

在多线程并发编程中 synchronized 一直是元老级角色，很多人都会称呼它为重量级锁。但是，随着 Java SE 1.6 对 synchronized 进行了各种优化之后，有些情况下它就并不那么重了。本文详细介绍 Java SE 1.6 中为了减少获得锁和释放锁带来的性能消耗而引入的偏向锁和轻量级锁，以及锁的存储结构和升级过程。

先来看下利用 synchronized 实现同步的基础：Java 中的每一个对象都可以作为锁。具体表现为以下3种形式：

- 对于普通同步方法，锁是当前实例对象。
- 对于静态同步方法，锁是当前类的 Class 对象。
- 对于同步方法块，锁是 Synchonized 括号里配置的对象。

### 监视器（monitor）机制

现在我们来看看 synchronized 的具体底层实现。先写一个简单的 demo :

```java
public class SynchronizedDemo {
    public static void main(String[] args) {
        synchronized (SynchronizedDemo.class) {
        }
        method();
    }

    private static void method() {
    }
}
```

上面的代码中有一个同步代码块，锁住的是类对象，并且还有一个同步静态方法，锁住的依然是该类的类对象。编译之后，切换到SynchronizedDemo.class 的同级目录之后，然后用 **javap -v SynchronizedDemo.class** 查看字节码文件：

 ![synchronizedDemo.class](./image/synchronizedDemo.class.png ':size=60%')

如图，上面用黄色高亮的部分就是需要注意的部分了，这也是添 Synchronized 关键字之后独有的。执行同步代码块后首先要先执行**monitorenter** 指令，退出的时候 **monitorexit** 指令。通过分析之后可以看出，使用 Synchronized 进行同步，其关键就是必须要对对象的监视器 monitor 进行获取，当线程获取 monitor 后才能继续往下执行，否则就只能等待。而这个获取的过程是**互斥**的，即同一时刻只有一个线程能够获取到 monitor。上面的 demo 中在执行完同步代码块之后紧接着再会去执行一个静态同步方法，而这个方法锁的对象依然就这个类对象，那么这个正在执行的线程还需要获取该锁吗？答案是不必的，从上图中就可以看出来，执行静态同步方法的时候就只有一条 monitorexit 指令，并没有 monitorenter 获取锁的指令。这就是**锁的重入性**，即在同一锁程中，线程不需要再次获取同一把锁。Synchronized 先天具有重入性。**每个对象拥有一个计数器，当线程获取该对象锁后，计数器就会加一，释放锁后就会将计数器减一**。

任意一个对象都拥有自己的监视器，当这个对象由同步块或者这个对象的同步方法调用时，执行方法的线程必须先获取该对象的监视器才能进入同步块和同步方法，如果没有获取到监视器的线程将会被阻塞在同步块和同步方法的入口处，进入到BLOCKED状态。

下图表现了对象，对象监视器，同步队列以及执行线程状态之间的关系：

 ![对象，对象监视器，同步队列和线程状态的关系](./image/对象，对象监视器，同步队列和线程状态的关系.png ':size=60%')

该图可以看出，任意线程对 Object 的访问，首先要获得 Object 的监视器，如果获取失败，该线程就进入同步状态，线程状态变为BLOCKED，当 Object 的监视器占有者释放后，在同步队列中得线程就会有机会重新获取该监视器。

### synchronized的happens-before关系

在上一篇文章中讨论过happens-before规则，抱着学以致用的原则我们现在来看一看Synchronized的happens-before规则，即监视器锁规则：对同一个监视器的解锁，happens-before于对该监视器的加锁。继续来看代码：

```java
public class MonitorDemo {
    private int a = 0;

    public synchronized void writer() {     // 1
        a++;                                // 2
    }                                       // 3

    public synchronized void reader() {    // 4
        int i = a;                         // 5
    }                                      // 6
}
```

该代码的happens-before关系如图所示：

 ![image-20220329175517472](./image/image-20220329175517472.png ':size=60%')

在图3-24中，每一个箭头链接的两个节点，代表了一个happens-before关系。黑色箭头表示程序顺序规则；橙色箭头表示监视器锁规则；蓝色箭头表示组合这些规则后提供的happens-before保证。

图3-24表示在线程A释放了锁之后，随后线程B获取同一个锁。在上图中，2 happens-before 5。因此，线程A在释放锁之前所有可见的共享变量，在线程B获取同一个锁之后，将立刻变得对B线程可见。

### 锁的释放和获取的内存语义

当线程释放锁时，JMM会把该线程对应的本地内存中的共享变量刷新到主内存中。以上面的MonitorExample程序为例，A线程释放锁后，共享数据的状态示意图如下图所示：

 ![image-20220329175827201](./image/image-20220329175827201.png ':size=60%')

当线程获取锁时，JMM会把该线程对应的本地内存置为无效。从而使得被监视器保护的临界区代码必须从主内存中读取共享变量。下图是锁获取的状态示意图：

 ![image-20220329175944110](./image/image-20220329175944110.png ':size=60%')

对比锁释放-获取的内存语义与volatile写-读的内存语义可以看出：锁释放与volatile写有相同的内存语义；锁获取与volatile读有相同的内存语义。

下面对锁释放和锁获取的内存语义做个总结：

- 线程A释放一个锁，实质上是线程A向接下来将要获取这个锁的某个线程发出了（线程A对共享变量所做修改的）消息。
- 线程B获取一个锁，实质上是线程B接收了之前某个线程发出的（在释放这个锁之前对共享变量所做修改的）消息。
- 线程A释放锁，随后线程B获取这个锁，这个过程实质上是线程A通过主内存向线程B发送消息。

### 锁内存语义的实现

这里将借助ReentrantLock的源代码，来分析锁内存语义的具体实现机制。

请看下面的示例代码。

```java
class ReentrantLockExample {
    int a = 0;
    ReentrantLock lock = new ReentrantLock();
    public void writer() {
        lock.lock(); // 获取锁
        try {
            a++;
        } finally {
            lock.unlock(); // 释放锁
        }
    }
    public void reader () {
        lock.lock(); // 获取锁
        try {
            int i = a;
            ……
        } finally {
            lock.unlock(); // 释放锁
        }
    }
}
```

在ReentrantLock中，调用lock()方法获取锁；调用unlock()方法释放锁。

ReentrantLock的实现依赖于Java同步器框架AbstractQueuedSynchronizer（本文简称之为AQS）。AQS使用一个**整型的volatile变量（命名为state）来维护同步状态**，马上我们会看到，这个volatile变量是ReentrantLock内存语义实现的关键。

下图是ReentrantLock的类图（仅画出与本文相关的部分）：

 ![image-20220329181026200](./image/image-20220329181026200.png ':size=70%')

ReentrantLock分为公平锁和非公平锁，我们首先分析公平锁。

使用公平锁时，加锁方法lock()调用轨迹如下。

1）ReentrantLock : lock()。

2）FairSync : lock()。

3）AbstractQueuedSynchronizer : acquire(int arg)。

4）ReentrantLock : tryAcquire(int acquires)。

在第4）步真正开始加锁，下面是该方法的源代码：

```java
protected final boolean tryAcquire(int acquires) {
    final Thread current = Thread.currentThread();
    int c = getState(); // 获取锁的开始，首先读volatile变量state
    if (c == 0) {
        if (isFirst(current) &&
            compareAndSetState(0, acquires)) {
            setExclusiveOwnerThread(current);
            return true;
        }
    }else if (current == getExclusiveOwnerThread()) {
        int nextc = c + acquires;
        if (nextc < 0)
            throw new Error("Maximum lock count exceeded");
        setState(nextc);
        return true;
    }
    return false;
}
```

从上面源代码中我们可以看出，加锁方法首先读volatile变量state。

在使用公平锁时，解锁方法unlock()调用轨迹如下。

1）ReentrantLock : unlock()。

2）AbstractQueuedSynchronizer : release(int arg)。

3）Sync : tryRelease(int releases)。

在第3步真正开始释放锁，下面是该方法的源代码：

```java
protected final boolean tryRelease(int releases) {
    int c = getState() - releases;
    if (Thread.currentThread() != getExclusiveOwnerThread())
        throw new IllegalMonitorStateException();
    boolean free = false;
    if (c == 0) {
        free = true;
        setExclusiveOwnerThread(null);
    }
    setState(c); // 释放锁的最后，写volatile变量state
    return free;
}
```

从上面的源代码可以看出，在释放锁的最后写volatile变量state。

公平锁在释放锁的最后写volatile变量state，在获取锁时首先读这个volatile变量。根据volatile的happens-before规则，释放锁的线程在写volatile变量之前可见的共享变量，在获取锁的线程读取同一个volatile变量后将立即变得对获取锁的线程可见。

现在我们来分析非公平锁的内存语义的实现。非公平锁的释放和公平锁完全一样，所以这里仅仅分析非公平锁的获取。使用非公平锁时，加锁方法lock()调用轨迹如下。

1）ReentrantLock : lock()。

2）NonfairSync : lock()。

3）AbstractQueuedSynchronizer : compareAndSetState(int expect,int update)。

在第3步真正开始加锁，下面是该方法的源代码：

```java
protected final boolean compareAndSetState(int expect, int update) {
    return unsafe.compareAndSwapInt(this, stateOffset, expect, update);
}
```

可以看到这里是以CAS的方法来更新state变量，要知道，**此操作具有volatile读和写的内存语义**。由此可知，其实非公平锁上锁的内存语义也是通过volatile实现。

现在对公平锁和非公平锁的内存语义做个**总结**：

- 公平锁和非公平锁释放时，最后都要写一个volatile变量state。
- 公平锁获取时，首先会去读volatile变量。
- 非公平锁获取时，首先会用CAS更新volatile变量，这个操作同时具有volatile读和volatile写的内存语义。

从本文对ReentrantLock的分析可以看出，锁释放-获取的内存语义的实现至少有下面两种方式：

1. 利用volatile变量的写-读所具有的内存语义。
2. 利用CAS所附带的volatile读和volatile写的内存语义。



### Java 对象头

在同步的时候是获取对象的 monitor ，即获取到对象的锁。那么对象的锁怎么理解？无非就是类似对对象的一个标志，那么这个标志就是存放在 Java 对象的对象头。Java 对象头里的 Mark Word 里默认的存放的对象的 Hashcode ，分代年龄和锁标记位。32位 JVM Mark Word默认存储结构为：

 ![image-20220327172334688](./image/image-20220327172334688.png ':size=70%')

如图在Mark Word会默认存放hasdcode，年龄值以及锁标志位等信息。

Java SE 1.6 中，锁一共有4种状态，级别从低到高依次是：**无锁状态、偏向锁状态、轻量级锁状态和重量级锁状态**，这几个状态会随着竞争情况逐渐升级。**锁可以升级但不能降级**，意味着偏向锁升级成轻量级锁后不能降级成偏向锁。这种锁升级却不能降级的策略，目的是为了提高获得锁和释放锁的效率。对象的MarkWord变化为下图：

 ![image-20220327172538381](./image/image-20220327172538381.png ':size=70%')

## 3、锁的状态的对比与升级

### 偏向锁

HotSpot 的作者经过研究发现，大多数情况下，锁不仅不存在多线程竞争，而且总是由同一线程多次获得，为了让线程获得锁的代价更低而引入了偏向锁。

> **偏向锁的获取**

当一个线程访问同步块并获取锁时，会在**对象头**和**栈帧中的锁记录**里存储锁偏向的线程 ID，以后该线程在进入和退出同步块时不需要进行 CAS 操作来加锁和解锁，只需简单地测试一下对象头的 Mark Word 里是否存储着指向当前线程的偏向锁。如果测试成功，表示线程已经获得了锁。如果测试失败，则需要再测试一下 Mark Word 中偏向锁的标识是否设置成1（表示当前是偏向锁）：如果没有设置，则使用 CAS 竞争锁；如果设置了，则尝试使用 CAS 将对象头的偏向锁指向当前线程。

> **偏向锁的撤销**

偏向锁使用了一种**等到竞争出现才释放锁**的机制，所以当其他线程尝试竞争偏向锁时，持有偏向锁的线程才会释放锁。

 ![偏向锁撤销流程](./image/偏向锁撤销流程.png ':size=40%')

如图，偏向锁的撤销，需要等待**全局安全点**（在这个时间点上没有正在执行的字节码）。它会首先暂停拥有偏向锁的线程，然后检查持有偏向锁的线程是否活着，如果线程不处于活动状态，则将对象头设置成无锁状态；如果线程仍然活着，拥有偏向锁的栈会被执行，遍历偏向对象的锁记录，栈中的锁记录和对象头的 Mark Word **要么**重新偏向于其他线程，**要么**恢复到无锁或者标记对象不适合作为偏向锁，最后唤醒暂停的线程。

下图线程1展示了偏向锁获取的过程，线程2展示了偏向锁撤销的过程。

 ![image-20220327173657164](./image/image-20220327173657164.png ':size=70%')

> **如何关闭偏向锁**

偏向锁在Java 6和Java 7里是默认启用的，但是它在应用程序启动几秒钟之后才激活，如有必要可以使用JVM参数来关闭延迟：**-XX:BiasedLockingStartupDelay=0**。如果你确定应用程序里所有的锁通常情况下处于竞争状态，可以通过JVM参数关闭偏向锁：**-XX:-UseBiasedLocking=false**，那么程序默认会进入轻量级锁状态。

### 轻量级锁

> **加锁**

线程在执行同步块之前，JVM 会先在当前线程的栈桢中**创建用于存储锁记录的空间**，并将对象头中的 Mark Word 复制到锁记录中，官方称为 **Displaced Mark Word** 。然后线程尝试使用 CAS **将对象头中的 Mark Word 替换为指向锁记录的指针**。如果成功，当前线程获得锁，如果失败，表示其他线程竞争锁，当前线程便尝试使用自旋来获取锁。

> **解锁**

轻量级解锁时，会使用原子的 CAS 操作将 Displaced Mark Word 替换回到对象头，如果成功，则表示没有竞争发生。如果失败，表示当前锁存在竞争，锁就会膨胀成重量级锁。下图是两个线程同时争夺锁，导致锁膨胀的流程图。

 ![image-20220328141205122](./image/image-20220328141205122.png ':size=70%')

因为自旋会消耗CPU，为了避免无用的自旋（比如获得锁的线程被阻塞住了），一旦锁升级成重量级锁，就不会再恢复到轻量级锁状态。当锁处于这个状态下，其他线程试图获取锁时，都会被阻塞住，当持有锁的线程释放锁之后会唤醒这些线程，被唤醒的线程就会进行新一轮的夺锁之争。

### 各种锁的比较

 ![image-20220328141254080](./image/image-20220328141254080.png ':size=70%')

> 参考文献

《java并发编程的艺术》

