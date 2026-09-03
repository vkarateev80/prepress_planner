# -*- coding: utf-8 -*-
"""Модели данных лицензионного сервера (SQLAlchemy, SQLite)."""
import datetime

from sqlalchemy import (
    Column, DateTime, ForeignKey, Integer, String, create_engine
)
from sqlalchemy.orm import declarative_base, relationship, sessionmaker

Base = declarative_base()


def utcnow() -> datetime.datetime:
    """Серверное время — источник истины (naive UTC; переопределяется в тестах)."""
    return datetime.datetime.utcnow()


class Device(Base):
    __tablename__ = "devices"
    id = Column(Integer, primary_key=True)
    machine_id = Column(String, unique=True, nullable=False, index=True)
    trial_started_at = Column(DateTime, nullable=True)
    trial_expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=utcnow)


class LicenseKey(Base):
    __tablename__ = "license_keys"
    id = Column(Integer, primary_key=True)
    key = Column(String, unique=True, nullable=False, index=True)
    max_devices = Column(Integer, default=3)
    created_at = Column(DateTime, default=utcnow)
    activations = relationship("Activation", back_populates="key")


class Activation(Base):
    __tablename__ = "activations"
    id = Column(Integer, primary_key=True)
    key_id = Column(Integer, ForeignKey("license_keys.id"), nullable=False)
    machine_id = Column(String, nullable=False)
    activated_at = Column(DateTime, default=utcnow)
    key = relationship("LicenseKey", back_populates="activations")


class Subscription(Base):
    __tablename__ = "subscriptions"
    id = Column(Integer, primary_key=True)
    machine_id = Column(String, nullable=False, index=True)
    tier = Column(String, default="month")  # month | year
    status = Column(String, default="active")  # active | canceled
    current_period_end = Column(DateTime, nullable=True)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)


def make_engine(db_url: str = "sqlite:///./license.db"):
    eng = create_engine(db_url, connect_args={"check_same_thread": False})
    Base.metadata.create_all(eng)
    return eng


def make_session(eng=None):
    if eng is None:
        eng = make_engine()
    return sessionmaker(bind=eng)()
